import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import tempfile
import time
import unittest
from pathlib import Path

from app import config as config_mod
from app import records, runner

FAKE_WRAPPER = str(Path(__file__).resolve().parent / "fake_bin" / "run_awr_fleet.sh")


def make_config(fleet_conf_path, max_run_minutes=1, env=None):
    cfg = config_mod.Config()
    cfg.fleet = config_mod.FleetParams(conf_path=str(fleet_conf_path), max_run_minutes=max_run_minutes)
    cfg.env = env or {}
    cfg.schedule = config_mod.ScheduleConfig()
    cfg.retention = config_mod.RetentionConfig()
    return cfg


def wait_until(predicate, timeout=10, interval=0.02):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


class RunnerTestBase(unittest.TestCase):
    def setUp(self):
        self.cwd = Path(tempfile.mkdtemp())
        (self.cwd / "reports").mkdir()
        self.data_dir = Path(tempfile.mkdtemp())
        self.conf_path = self.cwd / "fleet.conf"
        self.conf_path.write_text("good1|/@x\ngood2|/@y|detail\n", encoding="utf-8")
        self.cfg = make_config(self.conf_path)
        self.rm = runner.RunManager(
            self.cfg, data_dir=self.data_dir, cwd=self.cwd, wrapper_path=FAKE_WRAPPER
        )
        self.rm.start()

    def tearDown(self):
        self.rm.stop(timeout=5)


class FleetRunLifecycleTest(RunnerTestBase):
    def test_success_run(self):
        rec = self.rm.enqueue_fleet("manual")
        self.assertEqual(rec["state"], records.STATE_QUEUED)
        ok = wait_until(
            lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
            not in (records.STATE_QUEUED, records.STATE_RUNNING)
        )
        self.assertTrue(ok, "run did not complete in time")
        final = records.load_record(self.data_dir, rec["run_id"])
        self.assertEqual(final["state"], records.STATE_SUCCESS)
        self.assertEqual(final["exit_code"], 0)
        self.assertIsNotNone(final["report_path"])
        self.assertEqual(len(final["databases"]), 2)
        self.assertTrue((self.cwd / final["report_path"]).is_file())

    def test_partial_run_has_error_rows(self):
        import os

        os.environ["FAKE_FORCE_ERROR_ALIASES"] = "good1"
        try:
            rec = self.rm.enqueue_fleet("manual")
            wait_until(
                lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
                not in (records.STATE_QUEUED, records.STATE_RUNNING)
            )
            final = records.load_record(self.data_dir, rec["run_id"])
            self.assertEqual(final["state"], records.STATE_PARTIAL)
            statuses = {d["alias"]: d["status"] for d in final["databases"]}
            self.assertEqual(statuses["good1"], "ERROR")
            self.assertEqual(statuses["good2"], "OK")
        finally:
            del os.environ["FAKE_FORCE_ERROR_ALIASES"]

    def test_all_fail_is_failed_state(self):
        import os

        os.environ["FAKE_FORCE_ERROR_ALIASES"] = "good1,good2"
        try:
            rec = self.rm.enqueue_fleet("manual")
            wait_until(
                lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
                not in (records.STATE_QUEUED, records.STATE_RUNNING)
            )
            final = records.load_record(self.data_dir, rec["run_id"])
            # fake wrapper exits 3 when n_ok==0 -- no Report:/exit0 -> failed
            self.assertEqual(final["state"], records.STATE_FAILED)
            self.assertEqual(final["exit_code"], 3)
        finally:
            del os.environ["FAKE_FORCE_ERROR_ALIASES"]

    def test_manual_duplicate_fleet_conflict(self):
        import os

        os.environ["FAKE_SLEEP"] = "2"
        try:
            self.rm.enqueue_fleet("manual")
            with self.assertRaises(runner.ConflictError):
                self.rm.enqueue_fleet("manual")
        finally:
            del os.environ["FAKE_SLEEP"]

    def test_scheduled_duplicate_is_skipped_record(self):
        import os

        os.environ["FAKE_SLEEP"] = "2"
        try:
            self.rm.enqueue_fleet("manual")
            rec2 = self.rm.enqueue_fleet("schedule")
            self.assertEqual(rec2["state"], records.STATE_SKIPPED)
        finally:
            del os.environ["FAKE_SLEEP"]

    def test_workdir_null_when_dir_absent_on_success(self):
        # The fake wrapper (like the real one on a clean success) leaves no
        # fleet_work_* dir behind, so the finalized record must NOT advertise
        # a workdir that doesn't exist on disk.
        rec = self.rm.enqueue_fleet("manual")
        wait_until(
            lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
            not in (records.STATE_QUEUED, records.STATE_RUNNING)
        )
        final = records.load_record(self.data_dir, rec["run_id"])
        self.assertEqual(final["state"], records.STATE_SUCCESS)
        self.assertIsNotNone(final["wrapper_run_id"])
        self.assertIsNone(final["workdir"], "workdir must be null when the dir was deleted")

    def test_workdir_kept_when_dir_present_on_disk(self):
        import os

        wrapper_run_id = "990011"
        os.environ["FAKE_RUN_ID"] = wrapper_run_id
        workdir_name = records.fleet_workdir_name(wrapper_run_id)
        (self.cwd / "reports" / workdir_name).mkdir()
        try:
            rec = self.rm.enqueue_fleet("manual")
            wait_until(
                lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
                not in (records.STATE_QUEUED, records.STATE_RUNNING)
            )
            final = records.load_record(self.data_dir, rec["run_id"])
            self.assertEqual(final["state"], records.STATE_SUCCESS)
            self.assertEqual(final["wrapper_run_id"], wrapper_run_id)
            self.assertEqual(final["workdir"], workdir_name)
        finally:
            del os.environ["FAKE_RUN_ID"]

    def test_serial_execution_second_job_runs_after_first(self):
        r1 = self.rm.enqueue_fleet("manual")
        wait_until(
            lambda: records.load_record(self.data_dir, r1["run_id"])["state"]
            not in (records.STATE_QUEUED, records.STATE_RUNNING)
        )
        r2 = self.rm.enqueue_fleet("manual")
        wait_until(
            lambda: records.load_record(self.data_dir, r2["run_id"])["state"]
            not in (records.STATE_QUEUED, records.STATE_RUNNING)
        )
        f1 = records.load_record(self.data_dir, r1["run_id"])
        f2 = records.load_record(self.data_dir, r2["run_id"])
        self.assertLessEqual(f1["ended_at"], f2["started_at"] + 0.5)


class DetailRunTest(RunnerTestBase):
    def test_detail_regen_success_and_cleanup(self):
        rec = self.rm.enqueue_detail("good1", "manual")
        wait_until(
            lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
            not in (records.STATE_QUEUED, records.STATE_RUNNING)
        )
        final = records.load_record(self.data_dir, rec["run_id"])
        self.assertEqual(final["state"], records.STATE_SUCCESS)
        # New per-run-folder layout: reports/awr_fleet_<ts>_run<id>/detail_good1.html
        self.assertTrue(final["report_path"].startswith("reports/awr_fleet_"))
        self.assertTrue(final["report_path"].endswith("/detail_good1.html"))
        self.assertTrue((self.cwd / final["report_path"]).is_file())

        # the 1-row fleet HTML byproduct (index.html in the same run folder)
        # must be deleted, while the detail report next to it survives...
        run_dirs = [
            p for p in (self.cwd / "reports").glob("awr_fleet_2*_run*") if p.is_dir()
        ]
        self.assertEqual(len(run_dirs), 1, "expected exactly one per-run folder")
        run_dir = run_dirs[0]
        self.assertFalse((run_dir / "index.html").exists(), "byproduct fleet HTML was not cleaned up")
        self.assertTrue((run_dir / "detail_good1.html").is_file())

        # ...and so must the temp conf
        tmp_confs = list((self.data_dir / "tmp").glob("detail_good1_*"))
        self.assertEqual(tmp_confs, [], "temp detail conf was not cleaned up")

    def test_detail_unknown_alias_not_found(self):
        with self.assertRaises(runner.NotFoundError):
            self.rm.enqueue_detail("nosuchalias", "manual")

    def test_detail_manual_duplicate_per_alias_conflict(self):
        import os

        os.environ["FAKE_SLEEP"] = "2"
        try:
            self.rm.enqueue_detail("good1", "manual")
            with self.assertRaises(runner.ConflictError):
                self.rm.enqueue_detail("good1", "manual")
            # a different alias is NOT deduped against good1's in-flight job
            rec_other = self.rm.enqueue_detail("good2", "manual")
            self.assertEqual(rec_other["state"], records.STATE_QUEUED)
        finally:
            del os.environ["FAKE_SLEEP"]

    def test_detail_failed_when_wrapper_reports_detail_failed(self):
        import os

        os.environ["FAKE_DETAIL_FAIL_ALIASES"] = "good1"
        try:
            rec = self.rm.enqueue_detail("good1", "manual")
            wait_until(
                lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
                not in (records.STATE_QUEUED, records.STATE_RUNNING)
            )
            final = records.load_record(self.data_dir, rec["run_id"])
            self.assertEqual(final["state"], records.STATE_FAILED)
        finally:
            del os.environ["FAKE_DETAIL_FAIL_ALIASES"]

    def test_detail_forces_per_line_honoring_over_env_none(self):
        # A fleet-wide FLEET_DETAIL=none in [env] must never silently
        # swallow an explicit per-alias regen request.
        self.cfg.env["FLEET_DETAIL"] = "none"
        rec = self.rm.enqueue_detail("good1", "manual")
        wait_until(
            lambda: records.load_record(self.data_dir, rec["run_id"])["state"]
            not in (records.STATE_QUEUED, records.STATE_RUNNING)
        )
        final = records.load_record(self.data_dir, rec["run_id"])
        self.assertEqual(final["state"], records.STATE_SUCCESS)


class ClampAndRestartRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.cwd = Path(tempfile.mkdtemp())
        (self.cwd / "reports").mkdir()
        self.data_dir = Path(tempfile.mkdtemp())
        self.conf_path = self.cwd / "fleet.conf"
        self.conf_path.write_text("good1|/@x\n", encoding="utf-8")

    def test_max_run_minutes_clamp_kills_the_process(self):
        import os

        cfg = make_config(self.conf_path, max_run_minutes=1)
        # patch: fake wrapper sleeps far longer than our clamp allows --
        # RunManager's timeout unit is minutes, so shrink it artificially by
        # calling the low-level subprocess runner directly with a small
        # "minutes" value expressed via a monkeypatched wait. Simpler: drive
        # _run_subprocess directly with a sub-second budget by treating
        # max_run_minutes as seconds via a tiny helper config value is not
        # supported by the public API, so exercise the private method,
        # which is exactly what it does internally.
        rm = runner.RunManager(cfg, data_dir=self.data_dir, cwd=self.cwd, wrapper_path=FAKE_WRAPPER)
        os.environ["FAKE_SLEEP"] = "5"
        try:
            log_path = self.data_dir / "clamp_test.log"
            argv = ["bash", FAKE_WRAPPER, str(self.conf_path), "AUTO", "1", "4", "10", "1", "w"]
            env = rm._build_env()
            start = time.time()
            exit_code, timed_out = rm._run_subprocess(argv, env, str(log_path), max_run_minutes=0.02)
            elapsed = time.time() - start
            self.assertTrue(timed_out)
            self.assertLess(elapsed, 4, "clamp did not terminate the process promptly")
            self.assertNotEqual(exit_code, 0)
        finally:
            del os.environ["FAKE_SLEEP"]

    def test_startup_recovers_stuck_running_record(self):
        stuck = records.new_record("stuck1", records.KIND_FLEET, "manual")
        stuck["state"] = records.STATE_RUNNING
        stuck["started_at"] = time.time() - 10
        records.save_record(self.data_dir, stuck)

        cfg = make_config(self.conf_path)
        rm = runner.RunManager(cfg, data_dir=self.data_dir, cwd=self.cwd, wrapper_path=FAKE_WRAPPER)
        recovered = rm.start()
        try:
            self.assertIn("stuck1", recovered)
            final = records.load_record(self.data_dir, "stuck1")
            self.assertEqual(final["state"], records.STATE_FAILED)
        finally:
            rm.stop()


class StaleDetailConfCleanupTest(unittest.TestCase):
    def test_start_removes_leftover_detail_confs(self):
        cwd = Path(tempfile.mkdtemp())
        (cwd / "reports").mkdir()
        data_dir = Path(tempfile.mkdtemp())
        conf_path = cwd / "fleet.conf"
        conf_path.write_text("good1|/@x\n", encoding="utf-8")
        tmp_dir = data_dir / "tmp"
        tmp_dir.mkdir(parents=True)
        stale = tmp_dir / "detail_good1_abc123.conf"
        stale.write_text("good1|scott/tiger@ORCL|detail\n", encoding="utf-8")
        other = tmp_dir / "unrelated.txt"
        other.write_text("keep me", encoding="utf-8")

        rm = runner.RunManager(make_config(conf_path), data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            self.assertFalse(stale.exists())
            self.assertTrue(other.exists())
        finally:
            rm.stop(timeout=5)


class RetentionWiringTest(unittest.TestCase):
    """[retention] must actually be applied: at startup and after each job."""

    def _env(self, keep_fleet_runs, keep_days=0):
        cwd = Path(tempfile.mkdtemp())
        (cwd / "reports").mkdir()
        data_dir = Path(tempfile.mkdtemp())
        conf_path = cwd / "fleet.conf"
        conf_path.write_text("good1|/@x\n", encoding="utf-8")
        cfg = make_config(conf_path)
        cfg.retention = config_mod.RetentionConfig(
            keep_fleet_runs=keep_fleet_runs, keep_days=keep_days, keep_run_records=200
        )
        return cwd, data_dir, cfg

    def _old_fleet_record(self, cwd, data_dir, run_id, wrapper_id, age_days):
        folder = cwd / "reports" / ("awr_fleet_202601010000_run%s" % wrapper_id)
        folder.mkdir()
        (folder / "index.html").write_text("<html></html>", encoding="utf-8")
        rec = records.new_record(run_id, records.KIND_FLEET, "schedule")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = time.time() - age_days * 86400
        rec["queued_at"] = rec["started_at"]
        rec["report_path"] = "reports/%s/index.html" % folder.name
        records.save_record(data_dir, rec)
        return folder

    def test_prune_runs_at_startup(self):
        cwd, data_dir, cfg = self._env(keep_fleet_runs=1)
        old = self._old_fleet_record(cwd, data_dir, "old", "1", age_days=20)
        newer = self._old_fleet_record(cwd, data_dir, "newer", "2", age_days=10)
        rm = runner.RunManager(cfg, data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            self.assertFalse(old.exists())
            self.assertTrue(newer.exists())
        finally:
            rm.stop(timeout=5)

    def test_prune_runs_after_each_job_and_keeps_the_new_report(self):
        cwd, data_dir, cfg = self._env(keep_fleet_runs=1)
        rm = runner.RunManager(cfg, data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            old = self._old_fleet_record(cwd, data_dir, "old", "1", age_days=20)
            rec = rm.enqueue_fleet("manual")
            self.assertTrue(wait_until(lambda: not old.exists()), "old run folder was not pruned after the job")
            done = records.load_record(data_dir, rec["run_id"])
            self.assertEqual(done["state"], records.STATE_SUCCESS)
            self.assertTrue((cwd / done["report_path"]).is_file(), "the run that just finished must keep its report")
        finally:
            rm.stop(timeout=5)

    def test_zero_keep_values_never_delete_the_newest_run(self):
        cwd, data_dir, cfg = self._env(keep_fleet_runs=0, keep_days=0)
        cfg.retention.keep_run_records = 0
        rm = runner.RunManager(cfg, data_dir=data_dir, cwd=cwd, wrapper_path=FAKE_WRAPPER)
        rm.start()
        try:
            rec = rm.enqueue_fleet("manual")
            self.assertTrue(
                wait_until(
                    lambda: (records.load_record(data_dir, rec["run_id"]) or {}).get("state")
                    in records.TERMINAL_STATES
                )
            )
            rm._queue.join()
            done = records.load_record(data_dir, rec["run_id"])
            self.assertIsNotNone(done)
            self.assertTrue((cwd / done["report_path"]).is_file())
        finally:
            rm.stop(timeout=5)


class ShutdownTerminatesWrapperTest(unittest.TestCase):
    """stop() must not leave the wrapper running after the server is gone."""

    def setUp(self):
        self.cwd = Path(tempfile.mkdtemp())
        (self.cwd / "reports").mkdir()
        self.data_dir = Path(tempfile.mkdtemp())
        self.conf_path = self.cwd / "fleet.conf"
        self.conf_path.write_text("good1|/@x\n", encoding="utf-8")

    def test_stop_kills_a_running_wrapper_and_records_it(self):
        import os

        rm = runner.RunManager(
            make_config(self.conf_path), data_dir=self.data_dir, cwd=self.cwd, wrapper_path=FAKE_WRAPPER
        )
        rm.start()
        os.environ["FAKE_SLEEP"] = "30"
        try:
            rec = rm.enqueue_fleet("manual")
            queued = rm.enqueue_detail("good1", "manual")
            self.assertTrue(wait_until(lambda: rm._current_proc is not None), "wrapper never started")
            pid = rm._current_proc.pid
            started = time.time()
            rm.stop(timeout=5)
            self.assertLess(time.time() - started, 8, "stop() did not return promptly")
        finally:
            del os.environ["FAKE_SLEEP"]

        # the whole process group is gone (wrapper + its sleep child)
        def group_gone():
            try:
                os.killpg(pid, 0)
            except ProcessLookupError:
                return True
            except PermissionError:
                return False
            return False

        self.assertTrue(wait_until(group_gone, timeout=5), "wrapper process group still alive after stop()")
        done = records.load_record(self.data_dir, rec["run_id"])
        self.assertEqual(done["state"], records.STATE_FAILED)
        self.assertTrue(any("shutting down" in w for w in done["warnings"]))
        # the job queued behind it was not started
        self.assertEqual(records.load_record(self.data_dir, queued["run_id"])["state"], records.STATE_QUEUED)


if __name__ == "__main__":
    unittest.main()
