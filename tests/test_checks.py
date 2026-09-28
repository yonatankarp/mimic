"""The Settings health checks, proven in both directions.

    python3 tests/test_checks.py

Each check must go red when the thing it checks is missing and green when it's there. A check
that only ever showed green once hid a Mimic that wasn't running at all, so "green on this
Mac" proves nothing: this builds both worlds from scratch in a temp folder.
"""

import http.server
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "ui"), str(ROOT / "pipeline")]
import drawthings  # noqa: E402
import serve  # noqa: E402

IDS = ["engine", "models", "helpers", "blender", "space",
       "drawthings-app", "drawthings-api", "drawthings-model", "slicer"]


class FakeDrawThings(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


class Checks(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.lab = self.tmp / "lab"
        self.engine = self.lab / "vendor" / "pixal3d-cpp"
        self.apps = self.tmp / "Applications"
        self.bin = self.tmp / "bin"
        self.dt_models = self.tmp / "dt-models"
        for d in (self.tmp / "runs", self.apps, self.bin):
            d.mkdir(parents=True)
        self.patches = [
            mock.patch.object(serve, "LAB", self.lab),
            mock.patch.object(serve, "ENGINE", self.engine),
            mock.patch.object(serve, "RUNS", self.tmp / "runs"),
            mock.patch.object(serve, "APP_DIRS", [self.apps]),
            mock.patch.object(drawthings, "MODELS_DIR", self.dt_models),
            mock.patch.object(drawthings, "API", "http://127.0.0.1:9"),  # discard port: refused
            mock.patch.dict(os.environ, {"PATH": str(self.bin)}),
        ]
        os.environ.pop("DRAWTHINGS_MODEL", None)
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()

    def results(self, free_gb):
        usage = mock.Mock(free=free_gb * 1e9)
        with mock.patch.object(serve.shutil, "disk_usage", return_value=usage):
            got = {c["id"]: c["ok"] for c in serve.checks()}
        self.assertEqual(sorted(got), sorted(IDS), "a check was added or removed: update IDS")
        return got

    def executable(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def test_everything_missing_is_red(self):
        got = self.results(free_gb=1)
        self.assertEqual([i for i in IDS if got[i]], [], "these stayed green with nothing there")

    def test_everything_present_is_green(self):
        self.executable(self.engine / "build" / "trellis-cli", "exit 0")
        models = self.engine / "models" / "pixal3d-sv"
        models.mkdir(parents=True)
        (models / "pixal3d_shape_flow_1024_sv.gguf").write_bytes(b"x")
        self.executable(self.lab / ".venv" / "bin" / "python", "exit 0")
        self.executable(self.bin / "blender", "exit 0")
        (self.apps / "Draw Things.app").mkdir()
        (self.apps / "OrcaSlicer.app").mkdir()
        self.dt_models.mkdir()
        (self.dt_models / "flux_2_klein_4b_q8p.ckpt").write_bytes(b"x")
        server = http.server.HTTPServer(("127.0.0.1", 0), FakeDrawThings)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with mock.patch.object(drawthings, "API", f"http://127.0.0.1:{server.server_port}"):
                got = self.results(free_gb=100)
        finally:
            server.shutdown()
        self.assertEqual([i for i in IDS if not got[i]], [], "these stayed red with everything there")

    def test_an_engine_that_does_not_start_is_red(self):
        # Present but broken, like a copy whose libraries went missing: exists is not enough.
        self.executable(self.engine / "build" / "trellis-cli", "exit 1")
        self.assertFalse(self.results(free_gb=100)["engine"])


if __name__ == "__main__":
    unittest.main()
