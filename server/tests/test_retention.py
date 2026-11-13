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
        # A real file OUTSIDE reports_dir that the recorded path points at.
        outside = Path(tempfile.mkdtemp(dir=str(self.reports_dir.parent)))
        victim = outside / "victim.html"
        victim.write_text("do not delete", encoding="utf-8")
        rec = records.new_record("evil", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = self.now - 100 * 86400
        rec["report_path"] = "reports/../%s/victim.html" % outside.name
        records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(victim.exists(), "a path escaping reports_dir must never be deleted")

    def test_reports_dir_itself_is_never_deleted(self):
        stray = self.reports_dir / "adhoc_cli_report.html"
        stray.write_text("<html></html>", encoding="utf-8")
        for i, (report_path, workdir) in enumerate(
            [("reports/", None), ("reports/.", None), ("reports", None), (None, "."), (None, "")]
        ):
            rec = records.new_record("base%d" % i, records.KIND_FLEET, "manual")
            rec["state"] = records.STATE_SUCCESS
            rec["started_at"] = self.now - 100 * 86400
            rec["report_path"] = report_path
            rec["workdir"] = workdir
            records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(self.reports_dir.is_dir())
        self.assertTrue(stray.exists(), "reports/ itself must never be treated as an artifact")

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

    def _make_fleet_record_with_run_folder(self, run_id, age_days, detail_aliases=(), state=records.STATE_SUCCESS):
        """Current (v0.4.0+) per-run-folder layout: report_path points at
        index.html inside a shared awr_fleet_<ts>_run<id>/ folder that also
        holds one detail_<alias>.html per detail-flagged DB. The record's
        own run_id (a server-side records.py id, e.g. "r0") is independent
        of the folder's embedded wrapper RUN_ID, which the real wrapper
        always generates as digits -- so the folder name uses a numeric id
        derived from run_id, not run_id itself."""
        rec = records.new_record(run_id, records.KIND_FLEET, "manual")
        started = self.now - age_days * 86400
        rec["started_at"] = started
        rec["queued_at"] = started
        rec["ended_at"] = started + 60
        rec["state"] = state
        wrapper_run_id = "".join(c for c in run_id if c.isdigit()) or "1"
        folder_name = "awr_fleet_202607230000_run%s" % wrapper_run_id
        folder = self.reports_dir / folder_name
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "index.html").write_text("<html></html>", encoding="utf-8")
        for alias in detail_aliases:
            (folder / ("detail_%s.html" % alias)).write_text("<html></html>", encoding="utf-8")
        rec["report_path"] = "reports/%s/index.html" % folder_name
        records.save_record(self.data_dir, rec)
        return rec, folder

    def test_run_folder_deleted_wholesale_when_pruned(self):
        rec, folder = self._make_fleet_record_with_run_folder(
            "r0", age_days=100, detail_aliases=["prod_east", "prod_west"]
        )
        self.assertTrue(folder.is_dir())
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertFalse(
            folder.exists(),
            "the whole per-run folder (index.html + every detail report) must be pruned together",
        )

    def test_run_folder_kept_when_record_kept(self):
        rec, folder = self._make_fleet_record_with_run_folder("r0", age_days=1, detail_aliases=["prod_east"])
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=99, keep_days=99, keep_run_records=999)
        self.assertTrue(folder.is_dir())
        self.assertTrue((folder / "index.html").exists())
        self.assertTrue((folder / "detail_prod_east.html").exists())

    def test_run_folder_never_escapes_reports_dir(self):
        # A run-folder-shaped directory OUTSIDE reports_dir: the "delete the
        # whole run folder" expansion must not follow the path out.
        outside = Path(tempfile.mkdtemp(dir=str(self.reports_dir.parent)))
        folder = outside / "awr_fleet_1_run1"
        folder.mkdir()
        victim = folder / "index.html"
        victim.write_text("do not delete", encoding="utf-8")
        rec = records.new_record("evil2", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_SUCCESS
        rec["started_at"] = self.now - 100 * 86400
        rec["report_path"] = "reports/../%s/awr_fleet_1_run1/index.html" % outside.name
        records.save_record(self.data_dir, rec)
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertTrue(victim.exists())
        self.assertTrue(folder.is_dir())

    def test_run_folder_idempotent_second_pass_is_a_noop(self):
        self._make_fleet_record_with_run_folder("r0", age_days=100, detail_aliases=["prod_east"])
        retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        summary2 = retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, keep_fleet_runs=0, keep_days=0, keep_run_records=999)
        self.assertEqual(summary2["artifacts_pruned"], 0)


class RecordThinningTest(unittest.TestCase):
    """Pass 3 (keep_run_records) and the detail-report rules."""

    def setUp(self):
        self.data_dir = Path(tempfile.mkdtemp())
        self.reports_dir = Path(tempfile.mkdtemp())
        self.now = time.time()

    def _fleet(self, run_id, age_days, wrapper_id, state=records.STATE_SUCCESS):
        rec = records.new_record(run_id, records.KIND_FLEET, "manual")
        started = self.now - age_days * 86400
        rec["started_at"] = started
        rec["queued_at"] = started
        rec["state"] = state
        folder = self.reports_dir / ("awr_fleet_202607230000_run%s" % wrapper_id)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "index.html").write_text("<html></html>", encoding="utf-8")
        rec["report_path"] = "reports/%s/index.html" % folder.name
        records.save_record(self.data_dir, rec)
        return rec, folder

    def _detail(self, run_id, alias, age_days, wrapper_id, state=records.STATE_SUCCESS):
        rec = records.new_record(run_id, records.KIND_DETAIL, "manual", alias=alias)
        started = self.now - age_days * 86400
        rec["started_at"] = started
        rec["queued_at"] = started
        rec["state"] = state
        folder = self.reports_dir / ("awr_fleet_202607230000_run%s" % wrapper_id)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / ("detail_%s.html" % alias)).write_text("<html></html>", encoding="utf-8")
        rec["report_path"] = "reports/%s/detail_%s.html" % (folder.name, alias)
        records.save_record(self.data_dir, rec)
        return rec, folder

    def _prune(self, **kw):
        args = dict(keep_fleet_runs=999, keep_days=999, keep_run_records=999)
        args.update(kw)
        return retention.prune_runs(self.data_dir, reports_dir=self.reports_dir, **args)

    def test_dropping_a_record_also_deletes_its_artifacts(self):
        # keep_run_records smaller than keep_fleet_runs used to orphan the
        # report folder (record gone, files left forever).
        _, new_folder = self._fleet("new", 1, "1")
        _, old_folder = self._fleet("old", 5, "2")
        self._prune(keep_run_records=1)
        self.assertIsNotNone(records.load_record(self.data_dir, "new"))
        self.assertIsNone(records.load_record(self.data_dir, "old"))
        self.assertTrue(new_folder.is_dir())
        self.assertFalse(old_folder.exists())

    def test_queued_and_running_records_are_never_dropped(self):
        self._fleet("done", 1, "1")
        rec, _ = self._fleet("stuck", 50, "2", state=records.STATE_RUNNING)
        self._prune(keep_run_records=1)
        self.assertIsNotNone(records.load_record(self.data_dir, "stuck"))

    def test_old_detail_reports_are_pruned_but_latest_per_alias_survives(self):
        _, f_old = self._detail("d_old", "prod_east", 100, "10")
        _, f_new = self._detail("d_new", "prod_east", 90, "11")
        _, f_other = self._detail("d_other", "prod_west", 200, "12")
        self._prune(keep_days=30)
        self.assertFalse(f_old.exists(), "superseded detail report older than keep_days is pruned")
        self.assertTrue(f_new.exists(), "newest successful detail per alias is always kept")
        self.assertTrue(f_other.exists(), "the only detail report of an alias is always kept")
        self.assertTrue(records.load_record(self.data_dir, "d_old")["artifacts_pruned"])

    def test_recent_detail_reports_are_kept(self):
        _, f_a = self._detail("d_a", "prod_east", 2, "20")
        _, f_b = self._detail("d_b", "prod_east", 1, "21")
        self._prune(keep_days=30)
        self.assertTrue(f_a.exists())
        self.assertTrue(f_b.exists())

    def test_latest_detail_record_survives_record_thinning(self):
        _, f_detail = self._detail("d_only", "prod_east", 300, "30")
        for i in range(3):
            self._fleet("f%d" % i, i, str(40 + i))
        self._prune(keep_run_records=2)
        self.assertIsNotNone(records.load_record(self.data_dir, "d_only"))
        self.assertTrue(f_detail.exists())


if __name__ == "__main__":
    unittest.main()
