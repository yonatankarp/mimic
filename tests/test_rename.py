"""Renaming a mini from the gallery.

    python3 tests/test_rename.py

A mini is a folder whose STL and previews are named after it, and the page finds them by
that name, so a rename has to move all of them or the mini loses its print file.
"""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ui"))
import serve  # noqa: E402

NAMED = ["{n}.stl", "{n}_front.png", "{n}_side.png", "{n}_back.png"]


class Rename(unittest.TestCase):
    def setUp(self):
        self.runs = Path(tempfile.mkdtemp())
        self.patch = mock.patch.object(serve, "RUNS", self.runs)
        self.patch.start()
        d = self.runs / "dwarf"
        d.mkdir()
        for f in NAMED + ["source.png", "model.glb", "settings.json"]:
            (d / f.format(n="dwarf")).write_text(f)
        serve.job.update(running=False, name=None)

    def tearDown(self):
        self.patch.stop()

    def test_moves_the_folder_and_every_file_named_after_it(self):
        self.assertIsNone(serve.rename_run("dwarf", "dwarf-cleric"))
        d = self.runs / "dwarf-cleric"
        self.assertFalse((self.runs / "dwarf").exists())
        for f in NAMED:
            self.assertTrue((d / f.format(n="dwarf-cleric")).exists(), f)
        for f in ("source.png", "model.glb", "settings.json"):
            self.assertTrue((d / f).exists(), f)
        self.assertEqual(serve.list_runs()[0]["stl"], "dwarf-cleric.stl")

    def test_a_rename_keeps_the_minis_date_and_place(self):
        import os, time
        old = time.time() - 3 * 86400
        for f in (self.runs / "dwarf").iterdir():
            os.utime(f, (old, old))
        (self.runs / "newer").mkdir()
        (self.runs / "newer" / "newer.stl").write_text("x")
        serve.rename_run("dwarf", "dwarf-cleric")
        runs = serve.list_runs()
        self.assertEqual([r["name"] for r in runs], ["newer", "dwarf-cleric"], "a rename moved it to the top")
        self.assertAlmostEqual(runs[1]["mtime"], old, delta=2)

    def test_refuses_a_name_that_is_taken(self):
        (self.runs / "taken").mkdir()
        self.assertIn("already exists", serve.rename_run("dwarf", "taken"))
        self.assertTrue((self.runs / "dwarf" / "dwarf.stl").exists(), "a refused rename moved files")

    def test_refuses_while_the_mini_is_being_made(self):
        serve.job.update(running=True, name="dwarf")
        self.assertIn("still making", serve.rename_run("dwarf", "other"))
        serve.job.update(running=False)

    def test_unknown_mini(self):
        self.assertEqual(serve.rename_run("ghost", "x"), "not found")


if __name__ == "__main__":
    unittest.main()
