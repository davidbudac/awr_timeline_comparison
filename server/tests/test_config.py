import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import tempfile
import unittest
from pathlib import Path
from textwrap import dedent

from app import config as config_mod


class ConfigTest(unittest.TestCase):
    def _write(self, text):
        d = tempfile.mkdtemp()
        p = Path(d) / "server.conf"
        p.write_text(dedent(text), encoding="utf-8")
        return str(p)

    def test_minimal_valid_config(self):
        p = self._write(
            """
            [server]
            bind_host = 127.0.0.1
            port = 8765

            [fleet]
            conf_path = fleet.conf
            """
        )
        cfg = config_mod.load_config(p)
        self.assertEqual(cfg.bind_host, "127.0.0.1")
        self.assertEqual(cfg.port, 8765)
        self.assertEqual(cfg.fleet.target_end, "AUTO")
        self.assertEqual(cfg.fleet.step_unit, "w")
        self.assertFalse(cfg.schedule.enabled)

    def test_missing_conf_path_errors(self):
        p = self._write("[server]\nport = 8765\n")
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)

    def test_bad_step_unit_errors(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf
            step_unit = x
            """
        )
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)

    def test_bad_target_end_errors(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf
            target_end = not-a-date
            """
        )
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)

    def test_env_whitelist_rejects_unknown_key(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf

            [env]
            SOME_RANDOM_VAR = 1
            """
        )
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)

    def test_env_whitelist_accepts_known_keys(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf

            [env]
            FLEET_PAR = 8
            fleet_timeout = 300
            """
        )
        cfg = config_mod.load_config(p)
        self.assertEqual(cfg.env["FLEET_PAR"], "8")
        self.assertEqual(cfg.env["FLEET_TIMEOUT"], "300")

    def test_schedule_daily_requires_daily_at(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf

            [schedule]
            enabled = true
            mode = daily
            """
        )
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)

    def test_schedule_daily_at_parses_list(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf

            [schedule]
            enabled = true
            mode = daily
            daily_at = 02:00, 14:30
            """
        )
        cfg = config_mod.load_config(p)
        self.assertEqual(cfg.schedule.daily_at, ["02:00", "14:30"])

    def test_schedule_bad_hhmm_errors(self):
        p = self._write(
            """
            [fleet]
            conf_path = fleet.conf

            [schedule]
            enabled = true
            daily_at = 25:99
            """
        )
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)

    def test_retention_defaults(self):
        p = self._write("[fleet]\nconf_path = fleet.conf\n")
        cfg = config_mod.load_config(p)
        self.assertEqual(cfg.retention.keep_fleet_runs, 14)
        self.assertEqual(cfg.retention.keep_days, 30)
        self.assertEqual(cfg.retention.keep_run_records, 200)

    def test_bad_port_errors(self):
        p = self._write(
            """
            [server]
            port = 70000

            [fleet]
            conf_path = fleet.conf
            """
        )
        with self.assertRaises(config_mod.ConfigError):
            config_mod.load_config(p)


class ValidatorTest(unittest.TestCase):
    def test_v_posint(self):
        self.assertTrue(config_mod.v_posint("4"))
        self.assertFalse(config_mod.v_posint("0"))
        self.assertFalse(config_mod.v_posint("-1"))
        self.assertFalse(config_mod.v_posint("1.5"))

    def test_v_posdec(self):
        self.assertTrue(config_mod.v_posdec("1"))
        self.assertTrue(config_mod.v_posdec("0.25"))
        self.assertFalse(config_mod.v_posdec("0"))
        self.assertFalse(config_mod.v_posdec("0.0"))
        self.assertFalse(config_mod.v_posdec("abc"))

    def test_v_target_end(self):
        self.assertTrue(config_mod.v_target_end("AUTO"))
        self.assertTrue(config_mod.v_target_end("auto"))
        self.assertTrue(config_mod.v_target_end("2026-04-15 09:00"))
        self.assertFalse(config_mod.v_target_end("2026-13-40 09:00"))
        self.assertFalse(config_mod.v_target_end("not a date"))


if __name__ == "__main__":
    unittest.main()
