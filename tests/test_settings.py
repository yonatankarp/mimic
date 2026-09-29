"""What Mimic remembers about each mini, and what Try Again rebuilds from it.

    python3 tests/test_settings.py

The page's "Now: 34 mm tall · 25 mm base" line reads `made`, so only a run that finished may
write it; Try Again reads `requested` and the source, so it must rebuild the same command.
"""

import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ui"))
import serve  # noqa: E402

SIZES = {"height": "100", "base": "40", "nozzle": "0.4"}


class Settings(unittest.TestCase):
    def setUp(self):
        self.runs = Path(tempfile.mkdtemp())
        self.patch = mock.patch.object(serve, "RUNS", self.runs)
        self.patch.start()
        self.d = self.runs / "mini"
        self.d.mkdir()

    def tearDown(self):
        self.patch.stop()

    def run_job(self, cmd):
        t = threading.Thread(target=serve.run_job, args=("mini", "prep", cmd, None, SIZES))
        t.start()
        t.join(timeout=10)

    def test_a_finished_run_records_what_it_made(self):
        self.run_job(["true"])
        self.assertEqual(serve.read_settings(self.d).get("made"), SIZES)

    def test_a_failed_run_records_nothing(self):
        serve.write_settings(self.d, made={"height": "32"})
        self.run_job(["false"])
        self.assertEqual(serve.read_settings(self.d)["made"], {"height": "32"}, "a failure overwrote 'made'")

    def test_writes_merge(self):
        serve.write_settings(self.d, source="desc", desc="a dwarf")
        serve.write_settings(self.d, requested=SIZES)
        st = serve.read_settings(self.d)
        self.assertEqual((st["source"], st["desc"], st["requested"]), ("desc", "a dwarf", SIZES))

    def test_try_again_rebuilds_the_same_command(self):
        size_flags = ["--height", "100.0", "--base", "40.0", "--nozzle", "0.4"]
        mk = str(ROOT / "make_mini.sh")
        cases = {
            "picture": ({"source": "image", "restyle": False}, "generate",
                        [mk, "mini", "--image", str(self.d / "upload.img"), *size_flags]),
            "picture, redrawn": ({"source": "image", "restyle": True}, "generate",
                                 [mk, "mini", "--image", str(self.d / "upload.img"), "--restyle", *size_flags]),
            "description": ({"source": "desc", "desc": "a dwarf cleric"}, "generate",
                            [mk, "mini", "a dwarf cleric", *size_flags]),
            "resize": ({}, "prep", ["blender", "-b", "-P", str(ROOT / "pipeline" / "mini_prep.py"), "--",
                                    str(self.d / "model.glb"), str(self.d / "mini.stl"), *size_flags]),
        }
        for label, (st, kind, want) in cases.items():
            with self.subTest(label):
                self.assertEqual(serve.job_cmd(self.d, kind, {**st, "requested": SIZES}), want)

    def test_unreadable_settings_read_as_empty(self):
        (self.d / "settings.json").write_text("{ not json")
        self.assertEqual(serve.read_settings(self.d), {})


if __name__ == "__main__":
    unittest.main()
