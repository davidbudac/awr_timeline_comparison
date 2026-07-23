import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import json
import tempfile
import time
import unittest
from pathlib import Path

from app import config as config_mod
from app import records, runner, webapp


class FakeRunManager:
    """A minimal double so webapp tests don't need a real subprocess."""

    def __init__(self, data_dir):
        self.data_dir = data_dir
        self.enqueue_fleet_calls = []
        self.enqueue_detail_calls = []
        self.fleet_conflict = False
        self.detail_not_found = False
        self.detail_conflict = False

    def enqueue_fleet(self, trigger):
        self.enqueue_fleet_calls.append(trigger)
        if self.fleet_conflict:
            raise runner.ConflictError("a fleet run is already queued or running")
        rec = records.new_record(records.new_run_id(), records.KIND_FLEET, trigger)
        records.save_record(self.data_dir, rec)
        return rec

    def enqueue_detail(self, alias, trigger):
        self.enqueue_detail_calls.append((alias, trigger))
        if self.detail_not_found:
            raise runner.NotFoundError("unknown alias: %s" % alias)
        if self.detail_conflict:
            raise runner.ConflictError("busy")
        rec = records.new_record(records.new_run_id(), records.KIND_DETAIL, trigger, alias=alias)
        records.save_record(self.data_dir, rec)
        return rec

    def status(self):
        return {"current": None, "queued": [], "queue_length": 0}


class WebappTestBase(unittest.TestCase):
    def setUp(self):
        self.data_dir = Path(tempfile.mkdtemp())
        self.reports_dir = Path(tempfile.mkdtemp())
        fleet_conf = Path(tempfile.mkdtemp()) / "fleet.conf"
        fleet_conf.write_text("good1|/@x\ngood2|/@y|detail\n", encoding="utf-8")

        cfg = config_mod.Config()
        cfg.fleet = config_mod.FleetParams(conf_path=str(fleet_conf))
        cfg.env = {}
        cfg.schedule = config_mod.ScheduleConfig()
        cfg.retention = config_mod.RetentionConfig()

        self.rm = FakeRunManager(self.data_dir)
        self.ctx = webapp.AppContext(cfg, self.rm, scheduler=None, data_dir=self.data_dir, reports_dir=self.reports_dir)

    def dispatch(self, method, path, headers=None, body=b""):
        return webapp.dispatch(self.ctx, method, path, headers or {}, body)


class RouteMatrixTest(WebappTestBase):
    def test_healthz(self):
        r = self.dispatch("GET", "/healthz")
        self.assertEqual(r.status, 200)
        self.assertIn(b"ok", r.body)

    def test_home_page(self):
        r = self.dispatch("GET", "/")
        self.assertEqual(r.status, 200)
        self.assertIn("text/html", r.content_type)
        self.assertIn(b"AWR Fleet Server", r.body)

    def test_runs_page(self):
        r = self.dispatch("GET", "/runs")
        self.assertEqual(r.status, 200)

    def test_run_detail_page_404_for_missing(self):
        r = self.dispatch("GET", "/runs/nope")
        self.assertEqual(r.status, 404)

    def test_run_detail_page_found(self):
        rec = records.new_record("abc123", records.KIND_FLEET, "manual")
        records.save_record(self.data_dir, rec)
        r = self.dispatch("GET", "/runs/abc123")
        self.assertEqual(r.status, 200)
        self.assertIn(b"abc123", r.body)

    def test_unknown_route_404(self):
        r = self.dispatch("GET", "/this/does/not/exist")
        self.assertEqual(r.status, 404)

    def test_method_not_allowed(self):
        r = self.dispatch("POST", "/healthz")
        self.assertEqual(r.status, 405)

    def test_api_status(self):
        r = self.dispatch("GET", "/api/status")
        self.assertEqual(r.status, 200)
        data = json.loads(r.body)
        self.assertIn("run_manager", data)
        self.assertIn("scheduler", data)

    def test_api_runs_empty(self):
        r = self.dispatch("GET", "/api/runs")
        data = json.loads(r.body)
        self.assertEqual(data["runs"], [])

    def test_api_run_404(self):
        r = self.dispatch("GET", "/api/runs/nope")
        self.assertEqual(r.status, 404)

    def test_api_run_found(self):
        rec = records.new_record("xyz", records.KIND_FLEET, "manual")
        records.save_record(self.data_dir, rec)
        r = self.dispatch("GET", "/api/runs/xyz")
        self.assertEqual(r.status, 200)
        data = json.loads(r.body)
        self.assertEqual(data["run_id"], "xyz")

    def test_api_run_log_offset(self):
        rec = records.new_record("logrun", records.KIND_FLEET, "manual")
        rec["state"] = records.STATE_SUCCESS
        records.save_record(self.data_dir, rec)
        lp = records.log_path(self.data_dir, "logrun")
        lp.write_text("hello world", encoding="utf-8")
        r = self.dispatch("GET", "/api/runs/logrun/log?offset=6")
        self.assertEqual(r.status, 200)
        self.assertEqual(r.body, b"world")
        self.assertEqual(r.headers["X-Log-EOF"], "1")

    def test_api_run_log_404_for_missing_run(self):
        r = self.dispatch("GET", "/api/runs/nope/log")
        self.assertEqual(r.status, 404)


class PostEndpointsTest(WebappTestBase):
    def test_api_fleet_run_json_returns_202(self):
        r = self.dispatch("POST", "/api/fleet/run", headers={"Content-Type": "application/json"}, body=b"{}")
        self.assertEqual(r.status, 202)
        data = json.loads(r.body)
        self.assertIn("run_id", data)

    def test_api_fleet_run_conflict_json(self):
        self.rm.fleet_conflict = True
        r = self.dispatch("POST", "/api/fleet/run", headers={"Content-Type": "application/json"}, body=b"{}")
        self.assertEqual(r.status, 409)

    def test_api_fleet_run_form_redirects(self):
        r = self.dispatch(
            "POST",
            "/api/fleet/run",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=b"",
        )
        self.assertEqual(r.status, 303)
        self.assertTrue(r.headers["Location"].startswith("/runs/"))

    def test_api_fleet_run_conflict_form_redirects_home(self):
        self.rm.fleet_conflict = True
        r = self.dispatch(
            "POST",
            "/api/fleet/run",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=b"",
        )
        self.assertEqual(r.status, 303)
        self.assertTrue(r.headers["Location"].startswith("/?error="))

    def test_api_detail_run_json(self):
        r = self.dispatch(
            "POST",
            "/api/detail/run",
            headers={"Content-Type": "application/json"},
            body=json.dumps({"alias": "good1"}).encode("utf-8"),
        )
        self.assertEqual(r.status, 202)
        self.assertEqual(self.rm.enqueue_detail_calls, [("good1", "manual")])

    def test_api_detail_run_form(self):
        r = self.dispatch(
            "POST",
            "/api/detail/run",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=b"alias=good2",
        )
        self.assertEqual(r.status, 303)
        self.assertEqual(self.rm.enqueue_detail_calls, [("good2", "manual")])

    def test_api_detail_run_missing_alias(self):
        r = self.dispatch("POST", "/api/detail/run", headers={"Content-Type": "application/json"}, body=b"{}")
        self.assertEqual(r.status, 400)

    def test_api_detail_run_invalid_alias_rejected(self):
        r = self.dispatch(
            "POST",
            "/api/detail/run",
            headers={"Content-Type": "application/json"},
            body=json.dumps({"alias": "../../etc/passwd"}).encode("utf-8"),
        )
        self.assertEqual(r.status, 400)
        self.assertEqual(self.rm.enqueue_detail_calls, [])

    def test_api_detail_run_not_found(self):
        self.rm.detail_not_found = True
        r = self.dispatch(
            "POST",
            "/api/detail/run",
            headers={"Content-Type": "application/json"},
            body=json.dumps({"alias": "good1"}).encode("utf-8"),
        )
        self.assertEqual(r.status, 404)

    def test_api_detail_run_conflict(self):
        self.rm.detail_conflict = True
        r = self.dispatch(
            "POST",
            "/api/detail/run",
            headers={"Content-Type": "application/json"},
            body=json.dumps({"alias": "good1"}).encode("utf-8"),
        )
        self.assertEqual(r.status, 409)


class ReportServingTest(WebappTestBase):
    def setUp(self):
        super().setUp()
        (self.reports_dir / "awr_fleet_202607221200_run1.html").write_text("<html>ok</html>", encoding="utf-8")

    def test_serves_a_valid_report(self):
        r = self.dispatch("GET", "/reports/awr_fleet_202607221200_run1.html")
        self.assertEqual(r.status, 200)
        self.assertIn(b"ok", r.body)
        self.assertIn("text/html", r.content_type)

    def test_serves_a_report_inside_the_new_run_folder(self):
        run_dir = self.reports_dir / "awr_fleet_202607231200_run2"
        run_dir.mkdir()
        (run_dir / "index.html").write_text("<html>console</html>", encoding="utf-8")
        (run_dir / "detail_prod_east.html").write_text("<html>detail</html>", encoding="utf-8")

        r = self.dispatch("GET", "/reports/awr_fleet_202607231200_run2/index.html")
        self.assertEqual(r.status, 200)
        self.assertIn(b"console", r.body)

        r2 = self.dispatch("GET", "/reports/awr_fleet_202607231200_run2/detail_prod_east.html")
        self.assertEqual(r2.status, 200)
        self.assertIn(b"detail", r2.body)

    def test_rejects_two_levels_deep_inside_run_folder(self):
        run_dir = self.reports_dir / "awr_fleet_202607231200_run2" / "nested"
        run_dir.mkdir(parents=True)
        (run_dir / "index.html").write_text("<html>x</html>", encoding="utf-8")
        r = self.dispatch("GET", "/reports/awr_fleet_202607231200_run2/nested/index.html")
        self.assertEqual(r.status, 404)

    def test_rejects_non_run_folder_shaped_subdir(self):
        odd_dir = self.reports_dir / "not_a_run_folder"
        odd_dir.mkdir()
        (odd_dir / "index.html").write_text("<html>x</html>", encoding="utf-8")
        r = self.dispatch("GET", "/reports/not_a_run_folder/index.html")
        self.assertEqual(r.status, 404)

    def test_missing_report_404(self):
        r = self.dispatch("GET", "/reports/does_not_exist.html")
        self.assertEqual(r.status, 404)

    def test_path_traversal_dotdot_segment_404(self):
        r = self.dispatch("GET", "/reports/../../etc/passwd")
        self.assertEqual(r.status, 404)

    def test_path_traversal_encoded_slash_404(self):
        r = self.dispatch("GET", "/reports/..%2F..%2Fetc%2Fpasswd")
        self.assertEqual(r.status, 404)

    def test_path_traversal_encoded_dotdot_only_no_slash_treated_as_filename(self):
        # "..html" (no slash at all) is just a literal filename, not a
        # traversal attempt -- it fullmatches the allowlist and 404s only
        # because the file doesn't exist.
        r = self.dispatch("GET", "/reports/..html")
        self.assertEqual(r.status, 404)

    def test_non_html_extension_rejected(self):
        (self.reports_dir / "secrets.txt").write_text("nope", encoding="utf-8")
        r = self.dispatch("GET", "/reports/secrets.txt")
        self.assertEqual(r.status, 404)

    def test_absolute_path_style_rejected(self):
        r = self.dispatch("GET", "/reports//etc/passwd")
        self.assertEqual(r.status, 404)

    def test_null_byte_and_special_chars_rejected(self):
        for bad in ["/reports/%00.html", "/reports/;rm -rf.html", "/reports/<script>.html"]:
            with self.subTest(bad=bad):
                r = self.dispatch("GET", bad)
                self.assertEqual(r.status, 404)

    def test_symlink_escape_is_blocked(self):
        import os

        outside = Path(tempfile.mkdtemp()) / "secret.html"
        outside.write_text("top secret", encoding="utf-8")
        link = self.reports_dir / "escape.html"
        try:
            os.symlink(str(outside), str(link))
        except OSError:
            self.skipTest("symlinks not supported in this environment")
        r = self.dispatch("GET", "/reports/escape.html")
        self.assertEqual(r.status, 404)


class SafeReportPathUnitTest(unittest.TestCase):
    """Direct unit coverage of paths.safe_report_path independent of the
    HTTP layer, against the real (non-test) REPORTS_DIR constant."""

    def test_rejects_slash_in_filename_when_folder_not_run_shaped(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path("sub/dir.html"))

    def test_rejects_non_matching_extension(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path("evil.php"))

    def test_rejects_none(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path(None))

    def test_accepts_well_formed_name(self):
        from app import paths

        p = paths.safe_report_path("awr_fleet_202607221200_run123.html")
        self.assertIsNotNone(p)
        self.assertTrue(str(p).endswith("awr_fleet_202607221200_run123.html"))

    def test_accepts_run_folder_form(self):
        from app import paths

        p = paths.safe_report_path("awr_fleet_202607221200_run123/index.html")
        self.assertIsNotNone(p)
        self.assertTrue(str(p).endswith("awr_fleet_202607221200_run123/index.html"))

    def test_accepts_detail_file_inside_run_folder(self):
        from app import paths

        p = paths.safe_report_path("awr_fleet_202607221200_run123/detail_prod_east.html")
        self.assertIsNotNone(p)

    def test_rejects_run_folder_with_bad_filename_extension(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path("awr_fleet_202607221200_run123/detail.php"))

    def test_rejects_two_folder_segments(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path("awr_fleet_1_run1/nested/index.html"))

    def test_rejects_dotdot_folder_segment(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path("../etc/index.html"))

    def test_rejects_folder_not_matching_run_pattern(self):
        from app import paths

        self.assertIsNone(paths.safe_report_path("not_a_run_folder/index.html"))
        self.assertIsNone(paths.safe_report_path("awr_fleet_run1/index.html"))
        self.assertIsNone(paths.safe_report_path("awr_fleet_1_runX/index.html"))


if __name__ == "__main__":
    unittest.main()
