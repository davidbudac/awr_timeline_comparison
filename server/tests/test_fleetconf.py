import sys as _sys
from pathlib import Path as _Path

_SERVER_DIR = str(_Path(__file__).resolve().parents[1])
if _SERVER_DIR not in _sys.path:
    _sys.path.insert(0, _SERVER_DIR)

import tempfile
import unittest
from pathlib import Path

from app import fleetconf


class MaskConnParityTest(unittest.TestCase):
    """Port-parity table against run_awr_fleet.sh:249 mask_conn."""

    CASES = [
        ("/", "/"),
        ("/@prod_east_tns", "/@prod_east_tns"),
        ("/ as sysdba", "/ as sysdba"),
        ("user/pw@svc", "user/***@svc"),
        ("scott/tiger@ORCL", "scott/***@ORCL"),
        ("user/pw", "user/***"),
        ("bare_tns_alias", "bare_tns_alias"),
        # a connect string that happens to contain a pipe -- mask_conn itself
        # doesn't care, only parse_fleet_conf's field-splitting does.
        ("user/pw@svc|extra", "user/***@svc|extra"),
        # no '@' present, so the no-service-name branch fires -- it matches
        # greedily to end-of-string and only the username survives, exactly
        # like the bash original (verified against run_awr_fleet.sh's
        # mask_conn directly: 'user/pw|extra' -> 'user/***', NOT
        # 'user/***|extra' -- a real-world case only reachable when a
        # connect string embeds a literal '|' that isn't the '|detail' flag
        # AND has no '@svc').
        ("user/pw|extra", "user/***"),
        # empty password segment
        ("user/@svc", "user/***@svc"),
    ]

    def test_parity_table(self):
        for conn, expected in self.CASES:
            with self.subTest(conn=conn):
                self.assertEqual(fleetconf.mask_conn(conn), expected)


class ParseFleetConfTest(unittest.TestCase):
    def _write(self, text):
        d = tempfile.mkdtemp()
        p = Path(d) / "fleet.conf"
        p.write_text(text, encoding="utf-8")
        return str(p)

    def test_basic_entries(self):
        p = self._write("prod_east|/@prod_east_tns\nreporting|ro_user/pw@RPT\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertEqual(list(entries.keys()), ["prod_east", "reporting"])
        self.assertFalse(entries["prod_east"].detail)
        self.assertEqual(entries["prod_east"].conn, "/@prod_east_tns")
        self.assertEqual(entries["reporting"].conn_disp, "ro_user/***@RPT")

    def test_blank_and_comment_lines_ignored(self):
        p = self._write("\n  \n# a comment\n   # indented comment\nprod|/@x\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertEqual(list(entries.keys()), ["prod"])

    def test_detail_suffix_variants(self):
        p = self._write(
            "a|/@x|detail\n"
            "b|/@y|DETAIL\n"
            "c|/@z| Detail \n"
            "d|/@w\n"
        )
        entries = fleetconf.parse_fleet_conf(p)
        self.assertTrue(entries["a"].detail)
        self.assertEqual(entries["a"].conn, "/@x")
        self.assertTrue(entries["b"].detail)
        self.assertTrue(entries["c"].detail)
        self.assertFalse(entries["d"].detail)

    def test_connect_containing_pipe_not_confused_with_detail(self):
        # a connect string with an embedded '|' that does NOT end in the
        # exact "|detail" suffix must be preserved verbatim, not truncated.
        p = self._write("odd|user/pw@svc|with|pipes\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertFalse(entries["odd"].detail)
        self.assertEqual(entries["odd"].conn, "user/pw@svc|with|pipes")

    def test_connect_ending_in_pipe_detail_word_but_meant_literally(self):
        # a connect string that legitimately ends "|detail" is indistinguishable
        # from the flag -- this is documented behavior (fleet.conf.example),
        # not a bug: it always wins as the flag.
        p = self._write("x|user/pw@svc|detail\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertTrue(entries["x"].detail)
        self.assertEqual(entries["x"].conn, "user/pw@svc")

    def test_duplicate_alias_errors(self):
        p = self._write("a|/@x\na|/@y\n")
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf(p)

    def test_invalid_alias_errors(self):
        for bad_alias in ["has space", "has|pipe".split("|")[0] + "!", "", "x" * 31]:
            p = self._write("%s|/@x\n" % bad_alias)
            with self.assertRaises(fleetconf.FleetConfError):
                fleetconf.parse_fleet_conf(p)

    def test_missing_pipe_errors(self):
        p = self._write("just_an_alias_no_pipe\n")
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf(p)

    def test_empty_connect_errors(self):
        p = self._write("a|\n")
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf(p)

    def test_empty_connect_after_detail_suffix_strip_errors(self):
        p = self._write("a||detail\n")
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf(p)

    def test_connect_with_quote_errors(self):
        p = self._write("a|user/pw'x@svc\n")
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf(p)

    def test_no_usable_entries_errors(self):
        p = self._write("# just a comment\n\n")
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf(p)

    def test_missing_file_errors(self):
        with self.assertRaises(fleetconf.FleetConfError):
            fleetconf.parse_fleet_conf("/no/such/file/fleet.conf")

    def test_crlf_tolerated(self):
        p = self._write("a|/@x\r\nb|/@y\r\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertEqual(entries["a"].conn, "/@x")
        self.assertEqual(entries["b"].conn, "/@y")

    def test_alias_whitespace_trimmed(self):
        p = self._write("  padded  |/@x\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertIn("padded", entries)


class DetailConfLineTest(unittest.TestCase):
    def _write(self, text):
        d = tempfile.mkdtemp()
        p = Path(d) / "fleet.conf"
        p.write_text(text, encoding="utf-8")
        return str(p)

    def test_appends_detail_when_absent(self):
        p = self._write("a|/@x\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertEqual(fleetconf.detail_conf_line(entries["a"]), "a|/@x|detail")

    def test_verbatim_when_already_present(self):
        p = self._write("a|/@x|detail\n")
        entries = fleetconf.parse_fleet_conf(p)
        self.assertEqual(fleetconf.detail_conf_line(entries["a"]), "a|/@x|detail")


if __name__ == "__main__":
    unittest.main()
