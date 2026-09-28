"""The web UI's input checks: every query value ends up in a subprocess's argv.

    python3 tests/test_serve.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ui"))
import serve  # noqa: E402


class Names(unittest.TestCase):
    def test_accepts_plain_names(self):
        for name in ("dwarf-cleric", "tiefling2", "a"):
            self.assertTrue(serve.NAME_RE.fullmatch(name), name)

    def test_refuses_paths_and_flags(self):
        # A name becomes a directory under runs/ and an argument to make_mini.sh.
        for name in ("../etc", "a/b", "-rf", "--image", "", "Dwarf", "a b", "x" * 65, "a\n"):
            self.assertFalse(serve.NAME_RE.fullmatch(name), repr(name))


class PrepFlags(unittest.TestCase):
    def test_numbers_pass_through_as_floats(self):
        self.assertEqual(serve.prep_flags({"height": "38", "base": "25", "inflate": "0.08"}),
                         ["--height", "38.0", "--base", "25.0", "--inflate", "0.08"])

    def test_nobase_only_when_exactly_1(self):
        self.assertIn("--no-base", serve.prep_flags({"nobase": "1"}))
        self.assertNotIn("--no-base", serve.prep_flags({"nobase": "yes"}))

    def test_non_numbers_are_refused(self):
        for bad in ("32; rm -rf ~", "--image", "nan", "inf", "-5", ""):
            with self.assertRaises(ValueError, msg=bad):
                serve.prep_flags({"height": bad})

    def test_unknown_keys_are_dropped(self):
        self.assertEqual(serve.prep_flags({"voxel": "0.01", "stl": "/etc/passwd"}), [])


if __name__ == "__main__":
    unittest.main()
