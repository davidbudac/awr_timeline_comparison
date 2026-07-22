import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import datetime
import tempfile
import time
import unittest
from pathlib import Path

from app import config as config_mod
from app import runner, scheduler


def dt(y, mo, d, h, mi):
    return datetime.datetime(y, mo, d, h, mi)


class NextFireDailyTest(unittest.TestCase):
    def test_picks_next_upcoming_time_today(self):
        now = dt(2026, 7, 22, 10, 0)
        nf = scheduler.next_fire_daily(["02:00", "14:30", "23:00"], now)
        self.assertEqual(nf, dt(2026, 7, 22, 14, 30))

    def test_rolls_to_tomorrow_when_all_today_passed(self):
        now = dt(2026, 7, 22, 23, 30)
        nf = scheduler.next_fire_daily(["02:00", "14:30"], now)
        self.assertEqual(nf, dt(2026, 7, 23, 2, 0))

    def test_exactly_on_the_minute_is_not_a_match_strictly_after(self):
        now = dt(2026, 7, 22, 14, 30)
        nf = scheduler.next_fire_daily(["14:30"], now)
        self.assertEqual(nf, dt(2026, 7, 23, 14, 30))

    def test_empty_list_returns_none(self):
        self.assertIsNone(scheduler.next_fire_daily([], dt(2026, 7, 22, 10, 0)))

    def test_multiple_times_picks_earliest(self):
        now = dt(2026, 7, 22, 1, 0)
        nf = scheduler.next_fire_daily(["23:00", "03:00", "12:00"], now)
        self.assertEqual(nf, dt(2026, 7, 22, 3, 0))


class NextFireEveryTest(unittest.TestCase):
    def test_no_prior_fire_is_immediate(self):
        now = dt(2026, 7, 22, 10, 0)
        nf = scheduler.next_fire_every(24, now, None)
        self.assertEqual(nf, now)

    def test_anchored_to_last_fire(self):
        last = dt(2026, 7, 22, 10, 0)
        now = dt(2026, 7, 22, 11, 0)
        nf = scheduler.next_fire_every(6, now, last)
        self.assertEqual(nf, dt(2026, 7, 22, 16, 0))


class ComputeNextFireTest(unittest.TestCase):
    def test_daily_mode(self):
        cfg = config_mod.ScheduleConfig(mode="daily", daily_at=["05:00"])
        now = dt(2026, 7, 22, 1, 0)
        self.assertEqual(scheduler.compute_next_fire(cfg, now, None), dt(2026, 7, 22, 5, 0))

    def test_every_mode(self):
        cfg = config_mod.ScheduleConfig(mode="every", every_hours=12)
        last = dt(2026, 7, 22, 1, 0)
        now = dt(2026, 7, 22, 2, 0)
        self.assertEqual(scheduler.compute_next_fire(cfg, now, last), dt(2026, 7, 22, 13, 0))


class ApplyCatchupTest(unittest.TestCase):
    def test_not_due_yet_passes_through_unchanged(self):
        now = dt(2026, 7, 22, 10, 0)
        nf = dt(2026, 7, 22, 12, 0)
        cfg = config_mod.ScheduleConfig(mode="daily", daily_at=["12:00"])
        self.assertEqual(scheduler.apply_catchup(nf, now, True, cfg), nf)
        self.assertEqual(scheduler.apply_catchup(nf, now, False, cfg), nf)

    def test_overdue_with_catchup_true_fires_as_scheduled(self):
        now = dt(2026, 7, 22, 10, 0)
        nf = dt(2026, 7, 22, 8, 0)  # overdue by 2h
        cfg = config_mod.ScheduleConfig(mode="daily", daily_at=["08:00"])
        self.assertEqual(scheduler.apply_catchup(nf, now, True, cfg), nf)

    def test_overdue_daily_with_catchup_false_skips_to_next_day(self):
        now = dt(2026, 7, 22, 10, 0)
        nf = dt(2026, 7, 22, 8, 0)
        cfg = config_mod.ScheduleConfig(mode="daily", daily_at=["08:00"])
        result = scheduler.apply_catchup(nf, now, False, cfg)
        self.assertEqual(result, dt(2026, 7, 23, 8, 0))

    def test_overdue_every_with_catchup_false_advances_past_now(self):
        now = dt(2026, 7, 22, 10, 30)
        nf = dt(2026, 7, 22, 8, 0)  # a 6h cadence: 8:00 missed, 14:00 next
        cfg = config_mod.ScheduleConfig(mode="every", every_hours=6)
        result = scheduler.apply_catchup(nf, now, False, cfg)
        self.assertEqual(result, dt(2026, 7, 22, 14, 0))
        self.assertGreater(result, now)

    def test_overdue_every_with_catchup_false_advances_past_multiple_misses(self):
        # 3 whole cadence periods were missed while the server was down.
        now = dt(2026, 7, 22, 23, 0)
        nf = dt(2026, 7, 22, 8, 0)
        cfg = config_mod.ScheduleConfig(mode="every", every_hours=6)
        result = scheduler.apply_catchup(nf, now, False, cfg)
        # 8, 14, 20 all <= now(23:00); next is 02:00 the following day
        self.assertEqual(result, dt(2026, 7, 23, 2, 0))

    def test_none_next_fire_passes_through(self):
        cfg = config_mod.ScheduleConfig(mode="daily", daily_at=[])
        now = dt(2026, 7, 22, 10, 0)
        self.assertIsNone(scheduler.apply_catchup(None, now, True, cfg))
        self.assertIsNone(scheduler.apply_catchup(None, now, False, cfg))


class SchedulerThreadTest(unittest.TestCase):
    """Light integration test of the thread itself against the fake
    wrapper -- verifies an 'every' schedule with catchup fires immediately
    at startup and enqueues exactly one fleet run."""

    def setUp(self):
        self.cwd = Path(tempfile.mkdtemp())
        (self.cwd / "reports").mkdir()
        self.data_dir = Path(tempfile.mkdtemp())
        conf_path = self.cwd / "fleet.conf"
        conf_path.write_text("good1|/@x\n", encoding="utf-8")

        wrapper = str(Path(__file__).resolve().parent / "fake_bin" / "run_awr_fleet.sh")
        cfg = config_mod.Config()
        cfg.fleet = config_mod.FleetParams(conf_path=str(conf_path), max_run_minutes=1)
        cfg.env = {}
        cfg.schedule = config_mod.ScheduleConfig(enabled=True, mode="every", every_hours=24, catchup=True)
        cfg.retention = config_mod.RetentionConfig()
        self.cfg = cfg
        self.rm = runner.RunManager(cfg, data_dir=self.data_dir, cwd=self.cwd, wrapper_path=wrapper)
        self.rm.start()

    def tearDown(self):
        self.rm.stop()

    def test_catchup_fires_immediately_and_persists_state(self):
        sched = scheduler.Scheduler(self.cfg, self.rm, data_dir=self.data_dir, sleep_slice=0.05)
        sched.start()
        try:
            deadline = time.time() + 5
            fired = False
            while time.time() < deadline:
                from app import records

                recs = records.list_records(self.data_dir)
                if any(r.get("kind") == "fleet" for r in recs):
                    fired = True
                    break
                time.sleep(0.05)
            self.assertTrue(fired, "scheduler did not enqueue a fleet run on catchup")
            self.assertTrue((self.data_dir / "state.json").is_file())
        finally:
            sched.stop()

    def test_disabled_schedule_never_starts_thread(self):
        self.cfg.schedule.enabled = False
        sched = scheduler.Scheduler(self.cfg, self.rm, data_dir=self.data_dir, sleep_slice=0.05)
        sched.start()
        self.assertIsNone(sched._thread)


if __name__ == "__main__":
    unittest.main()
