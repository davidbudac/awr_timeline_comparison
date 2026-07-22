import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import json
import tempfile
import unittest
from pathlib import Path

from app import records


class ParseFleetSummaryTest(unittest.TestCase):
    def test_all_ok(self):
        text = (
            "prod_east                OK     score=16   crit=1 warn=2 suppressed=0 topsql_n=3 topsql_pts=25 detail=ok\n"
            "prod_west                OK     score=3    crit=0 warn=1 suppressed=0 topsql_n=1 topsql_pts=3 detail=-\n"
            "Report: reports/awr_fleet_202607221200_run20260722120005123.html\n"
        )
        r = records.parse_fleet_summary(text)
        self.assertEqual(len(r["databases"]), 2)
        self.assertEqual(r["databases"][0]["alias"], "prod_east")
        self.assertEqual(r["databases"][0]["status"], "OK")
        self.assertEqual(r["databases"][0]["score"], "16")
        self.assertEqual(r["databases"][1]["detail"], "-")
        self.assertEqual(r["wrapper_run_id"], "20260722120005123")
        self.assertEqual(r["report_path"], "reports/awr_fleet_202607221200_run20260722120005123.html")

    def test_mixed_error(self):
        text = (
            "deadbox                  ERROR  rc=1     detail=-       simulated failure for deadbox\n"
            "prod_east                OK     score=16   crit=1 warn=2 suppressed=0 topsql_n=3 topsql_pts=25 detail=ok\n"
            "Report: reports/awr_fleet_202607221200_run20260722120005123.html\n"
        )
        r = records.parse_fleet_summary(text)
        self.assertEqual(r["databases"][0]["status"], "ERROR")
        self.assertEqual(r["databases"][0]["rc"], "1")
        self.assertEqual(r["databases"][0]["reason"], "simulated failure for deadbox")
        self.assertEqual(r["databases"][1]["status"], "OK")
        self.assertIsNotNone(r["report_path"])

    def test_detail_failed(self):
        text = (
            "prod_east                OK     score=16   crit=1 warn=2 suppressed=0 topsql_n=3 topsql_pts=25 detail=failed\n"
            "Report: reports/awr_fleet_202607221200_run1.html\n"
        )
        r = records.parse_fleet_summary(text)
        self.assertEqual(r["databases"][0]["detail"], "failed")

    def test_exit2_no_report_line(self):
        text = "error: fleet.conf 'x.conf' does not exist or is not readable.\n"
        r = records.parse_fleet_summary(text)
        self.assertEqual(r["databases"], [])
        self.assertIsNone(r["report_path"])
        self.assertIsNone(r["wrapper_run_id"])

    def test_garbage_interleaved_lines_ignored(self):
        text = (
            "Some banner text\n"
            "Keeping workdir 'reports/fleet_work_123' for debugging (1 DB error(s), 0 detail failure(s)).\n"
            "prod_east                OK     score=16   crit=1 warn=2 suppressed=0 topsql_n=3 topsql_pts=25 detail=ok\n"
            "warning: unresolved __FLEET_* placeholder(s) survived assembly -- this is a bug.\n"
            "Report: reports/awr_fleet_202607221200_run9.html\n"
            "Hint: 1 detailed report(s) hit the 3600s FLEET_DETAIL_TIMEOUT.\n"
        )
        r = records.parse_fleet_summary(text)
        self.assertEqual(len(r["databases"]), 1)
        self.assertEqual(r["databases"][0]["alias"], "prod_east")
        self.assertEqual(r["wrapper_run_id"], "9")

    def test_empty_text(self):
        r = records.parse_fleet_summary("")
        self.assertEqual(r["databases"], [])
        self.assertIsNone(r["report_path"])

    def test_detail_filename_and_workdir_helpers(self):
        self.assertEqual(
            records.detail_report_filename("prod_east", "12345"),
            "awr_fleet_detail_prod_east_run12345.html",
        )
        self.assertEqual(records.fleet_workdir_name("12345"), "fleet_work_12345")


class RecordPersistenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_save_and_load_roundtrip(self):
        rec = records.new_record("run1", records.KIND_FLEET, "manual")
        records.save_record(self.tmp, rec)
        loaded = records.load_record(self.tmp, "run1")
        self.assertEqual(loaded["run_id"], "run1")
        self.assertEqual(loaded["state"], records.STATE_QUEUED)

    def test_load_missing_returns_none(self):
        self.assertIsNone(records.load_record(self.tmp, "nope"))

    def test_atomic_write_leaves_no_tmp_files(self):
        rec = records.new_record("run1", records.KIND_FLEET, "manual")
        records.save_record(self.tmp, rec)
        leftover = list((Path(self.tmp) / "runs").glob(".tmp-*"))
        self.assertEqual(leftover, [])

    def test_list_records_sorted_newest_first(self):
        r1 = records.new_record("a", records.KIND_FLEET, "manual")
        r1["queued_at"] = 100
        r2 = records.new_record("b", records.KIND_FLEET, "manual")
        r2["queued_at"] = 200
        records.save_record(self.tmp, r1)
        records.save_record(self.tmp, r2)
        listed = records.list_records(self.tmp)
        self.assertEqual([r["run_id"] for r in listed], ["b", "a"])

    def test_list_records_skips_corrupt_json(self):
        runs_dir = Path(self.tmp) / "runs"
        runs_dir.mkdir(parents=True, exist_ok=True)
        (runs_dir / "corrupt.json").write_text("{not valid json", encoding="utf-8")
        r1 = records.new_record("a", records.KIND_FLEET, "manual")
        records.save_record(self.tmp, r1)
        listed = records.list_records(self.tmp)
        self.assertEqual([r["run_id"] for r in listed], ["a"])

    def test_recover_stuck_running(self):
        r1 = records.new_record("a", records.KIND_FLEET, "manual")
        r1["state"] = records.STATE_RUNNING
        r1["started_at"] = 1000.0
        records.save_record(self.tmp, r1)
        r2 = records.new_record("b", records.KIND_FLEET, "manual")
        r2["state"] = records.STATE_SUCCESS
        records.save_record(self.tmp, r2)

        recovered = records.recover_stuck_running(self.tmp)
        self.assertEqual(recovered, ["a"])
        loaded = records.load_record(self.tmp, "a")
        self.assertEqual(loaded["state"], records.STATE_FAILED)
        self.assertIn("restarted", loaded["error"])
        # unrelated terminal record left alone
        loaded_b = records.load_record(self.tmp, "b")
        self.assertEqual(loaded_b["state"], records.STATE_SUCCESS)

    def test_new_run_id_unique(self):
        ids = {records.new_run_id() for _ in range(50)}
        self.assertEqual(len(ids), 50)


if __name__ == "__main__":
    unittest.main()
