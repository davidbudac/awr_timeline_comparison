import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import tempfile
import time
import unittest
from pathlib import Path

from app import records, retention


class PruneRunsTest(unittest.TestCase):
    def setUp(self):
        self.data_dir = Path(tempfile.mkdtemp())
        self.reports_dir = Path(tempfile.mkdtemp())
        self.now = time.time()

    def _make_fleet_record(self, run_id, age_days, report_name=None, workdir_name=None, state=records.STATE_SUCCESS):
        rec = records.new_record(run_id, records.KIND_FLEET, "manual")
        started = self.now - age_days * 86400
        rec["started_at"] = started
        rec["queued_at"] = started
        rec["ended_at"] = started + 60
        rec["state"] = state
        if report_name:
            (self.reports_dir / report_name).write_text("<html></html>", encoding="utf-8")
            rec["report_path"] = "reports/%s" % report_name
        if workdir_name:
            wd = self.reports_dir / workdir_name
            wd.mkdir(parents=True, exist_ok=True)
            (wd / "manifest.tsv").write_text("a\tb\tN\n", encoding="utf-8")
            rec["workdir"] = workdir_name
        records.save_record(self.data_dir, rec)
        return rec

    def test_keeps_newest_n_and_prunes_the_rest(self):
        for i in range(5):
            self._make_fleet_record(
                "r%d" % i, age_days=i * 40, report_name="report_r%d.html" % i, workdir_name="work_r%d" % i
            )
        summary = retention.prune_runs(
            self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=2, keep_days=0, keep_run_records=999
        )
        self.assertEqual(summary["fleet_kept"], 2)
        # newest two (r0, r1) survive on disk; the rest are pruned
        self.assertTrue((self.reports_dir / "report_r0.html").exists())
        self.assertTrue((self.reports_dir / "report_r1.html").exists())
        for i in range(2, 5):
            self.assertFalse((self.reports_dir / ("report_r%d.html" % i)).exists())
            self.assertFalse((self.reports_dir / ("work_r%d" % i)).exists())
        # records themselves are NOT deleted by pass 1, only artifacts
        for i in range(5):
            self.assertIsNotNone(records.load_record(self.data_dir, "r%d" % i))

    def test_keep_days_overrides_keep_fleet_runs(self):
        self._make_fleet_record("recent", age_days=1, report_name="recent.html")
        self._make_fleet_record("old", age_days=100, report_name="old.html")
        # keep_fleet_runs=0 would prune everything by count, but keep_days=7
        # should still save the recent one.
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=7, keep_run_records=999)
        self.assertTrue((self.reports_dir / "recent.html").exists())
        self.assertFalse((self.reports_dir / "old.html").exists())

    def test_never_touches_files_it_did_not_record(self):
        stray = self.reports_dir / "awr_fleet_20260101_run1.html"
        stray.write_text("<html></html>", encoding="utf-8")
        self._make_fleet_record("r0", age_days=100, report_name="tracked.html")
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(stray.exists(), "an untracked report must never be deleted")
        self.assertFalse((self.reports_dir / "tracked.html").exists())

    def test_path_traversal_in_record_is_ignored(self):
        rec = records.new_record("evil", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = self.now - 100 * 86400
        rec["report_path"] = "reports/../../etc/passwd"
        records.save_record(self.data_dir, rec)
        # must not raise, and must not touch anything outside reports_dir
        outside_target = self.reports_dir.parent / "etc_passwd_sentinel"
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertFalse(outside_target.exists())

    def test_thins_old_records_and_logs_beyond_keep_run_records(self):
        for i in range(5):
            rec = self._make_fleet_record("r%d" % i, age_days=i)
            lp = records.log_path(self.data_dir, "r%d" % i)
            lp.write_text("log for r%d" % i, encoding="utf-8")
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=999, keep_days=999, keep_run_records=2)
        # newest 2 (r0, r1) keep both record + log
        self.assertIsNotNone(records.load_record(self.data_dir, "r0"))
        self.assertIsNotNone(records.load_record(self.data_dir, "r1"))
        self.assertTrue(records.log_path(self.data_dir, "r0").exists())
        # older ones lose record + log entirely
        for i in range(2, 5):
            self.assertIsNone(records.load_record(self.data_dir, "r%d" % i))
            self.assertFalse(records.log_path(self.data_dir, "r%d" % i).exists())

    def test_non_terminal_records_are_never_artifact_pruned(self):
        rec = records.new_record("running1", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_RUNNING
        rec["started_at"] = self.now - 100 * 86400
        (self.reports_dir / "inflight.html").write_text("x", encoding="utf-8")
        rec["report_path"] = "reports/inflight.html"
        records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue((self.reports_dir / "inflight.html").exists())

    def test_idempotent_second_pass_is_a_noop(self):
        self._make_fleet_record("r0", age_days=100, report_name="r0.html")
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        summary2 = retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertEqual(summary2["artifacts_pruned"], 0)


if __name__ == "__main__":
    unittest.main()
