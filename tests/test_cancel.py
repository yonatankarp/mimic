"""Stopping a mini that's being made.

    python3 tests/test_cancel.py

A job is a chain of programs (make_mini.sh starts the 3D engine, which runs for minutes), so
Stop has to end the whole chain, not just the script at the top of it.
"""

import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ui"))
import serve  # noqa: E402


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Cancel(unittest.TestCase):
    def setUp(self):
        self.runs = Path(tempfile.mkdtemp())
        self.patch = mock.patch.object(serve, "RUNS", self.runs)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def start(self, kind):
        run = self.runs / "mini"
        run.mkdir()
        child_pid = run / "child.pid"
        # A parent that starts a long-running child, like make_mini.sh starting the 3D engine.
        cmd = ["bash", "-c", f"sleep 60 & echo $! > {child_pid}; wait"]
        t = threading.Thread(target=serve.run_job, args=("mini", kind, cmd), daemon=True)
        t.start()
        for _ in range(100):
            if child_pid.exists() and child_pid.read_text().strip():
                break
            time.sleep(0.05)
        return t, int(child_pid.read_text())

    def test_stop_ends_the_job_and_everything_it_started(self):
        t, child = self.start("prep")
        self.assertTrue(serve.job["running"])
        self.assertTrue(serve.cancel_job())
        t.join(timeout=10)
        self.assertFalse(t.is_alive(), "the job didn't end")
        self.assertFalse(serve.job["running"])
        self.assertTrue(serve.job["canceled"], "a stop must read as stopped, not failed")
        time.sleep(0.2)
        self.assertFalse(alive(child), "Stop left the job's child program running")

    def test_a_stopped_new_mini_goes_to_the_trash(self):
        with mock.patch.object(serve.subprocess, "run") as run:
            t, _ = self.start("generate")
            serve.cancel_job()
            t.join(timeout=10)
        trashed = [c.args[0] for c in run.call_args_list if c.args and c.args[0][0] == "/usr/bin/trash"]
        self.assertEqual(trashed, [["/usr/bin/trash", str(self.runs / "mini")]])

    def test_nothing_to_stop(self):
        serve.job["running"] = False
        self.assertFalse(serve.cancel_job())


if __name__ == "__main__":
    unittest.main()
