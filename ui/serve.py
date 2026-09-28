#!/usr/bin/env python3
"""Mini Forge: a local web UI over make_mini.sh and mini_prep.py.

    python3 ~/Projects/minis/ui/serve.py      # then open http://127.0.0.1:8765

Stdlib only. One job at a time: Pixal3D and Blender both want the whole machine.
"""

import json
import math
import os
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
RUNS = ROOT / "runs"
UI = Path(__file__).resolve().parent
PORT = 8765
NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")  # used with fullmatch: "$" admits a trailing newline
TYPES = {".html": "text/html; charset=utf-8", ".png": "image/png", ".stl": "model/stl",
         ".glb": "model/gltf-binary", ".json": "application/json", ".log": "text/plain; charset=utf-8"}

job = {"running": False, "name": None, "kind": None, "log": "", "exit": None, "started": 0}
lock = threading.Lock()


def prep_flags(q):
    """Only the knobs mini_prep.py knows, as numbers: nothing from the query reaches a shell."""
    flags = []
    for key in ("height", "base", "inflate"):
        if key in q:
            value = float(q[key])
            if not math.isfinite(value) or value < 0:  # float() also takes "nan" and "inf"
                raise ValueError(key)
            flags += [f"--{key}", str(value)]
    if q.get("nobase") == "1":
        flags.append("--no-base")
    return flags


def run_job(name, kind, cmd, env=None):
    log = RUNS / name / f"{kind}.job.log"
    with lock:
        job.update(running=True, name=name, kind=kind, log="", exit=None, started=time.time())
    with open(log, "w") as fh:
        p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, env=env)
        code = p.wait()
    with lock:
        job.update(running=False, exit=code, log=log.read_text(errors="replace"))


def job_status():
    with lock:
        s = dict(job)
    if s["running"] and s["name"]:
        run = RUNS / s["name"]
        logf = run / f"{s['kind']}.job.log"
        s["log"] = logf.read_text(errors="replace") if logf.exists() else ""
        px = run / "pixal3d.log"
        # Pixal3D redraws its progress with \r; the last segment is the live line.
        if "[2/3]" in s["log"] and "[3/3]" not in s["log"] and px.exists():
            tail = px.read_bytes()[-4000:].decode(errors="replace").replace("\r", "\n")
            lines = [l.strip() for l in tail.splitlines() if l.strip()]
            s["detail"] = lines[-1] if lines else ""
    s["elapsed"] = int(time.time() - s["started"]) if s["started"] else 0
    return s


def list_runs():
    out = []
    for d in sorted((p for p in RUNS.iterdir() if p.is_dir()), key=lambda p: p.stat().st_mtime, reverse=True):
        files = {f.name for f in d.iterdir()}
        stl = f"{d.name}.stl"
        out.append({"name": d.name, "stl": stl if stl in files else None,
                    "source": "source.png" in files,
                    "renders": [v for v in ("front", "side", "back") if f"{d.name}_{v}.png" in files],
                    "mtime": int(d.stat().st_mtime)})
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path):
        self.send_response(200)
        self.send_header("Content-Type", TYPES.get(path.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(path.stat().st_size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with open(path, "rb") as fh:
            shutil.copyfileobj(fh, self.wfile)

    def query(self):
        return {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}

    def run_dir(self, q):
        name = q.get("name", "")
        if not NAME_RE.fullmatch(name):
            self.send(400, {"error": "name: lowercase letters, digits and dashes only"})
            return None
        return RUNS / name

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            return self.send_file(UI / "index.html")
        if path == "/api/runs":
            return self.send(200, list_runs())
        if path == "/api/job":
            return self.send(200, job_status())
        m = re.match(r"^/runs/([a-z0-9-]+)/([A-Za-z0-9_.-]+)$", path)
        if m:
            f = (RUNS / m[1] / m[2]).resolve()
            if f.is_relative_to(RUNS.resolve()) and f.is_file():
                return self.send_file(f)
        self.send(404, {"error": "not found"})

    def do_POST(self):
        path, q = urlparse(self.path).path, self.query()
        d = self.run_dir(q)
        if d is None:
            return
        name = d.name

        if path in ("/api/generate", "/api/prep"):
            with lock:
                if job["running"]:
                    return self.send(409, {"error": f"busy with {job['name']}"})
                job["running"] = True  # claim before the thread starts
            try:
                flags = prep_flags(q)
            except ValueError:
                with lock:
                    job["running"] = False
                return self.send(400, {"error": "height/base/inflate must be numbers"})

            if path == "/api/prep":
                if not (d / "model.glb").exists():
                    with lock:
                        job["running"] = False
                    return self.send(400, {"error": "no model yet: generate first"})
                cmd = ["blender", "-b", "-P", str(ROOT / "pipeline" / "mini_prep.py"), "--",
                       str(d / "model.glb"), str(d / f"{name}.stl"), *flags]
                env = None
            else:
                if (d / "model.glb").exists():
                    with lock:
                        job["running"] = False
                    return self.send(409, {"error": f"'{name}' already exists: pick a new name, or Re-prep it"})
                d.mkdir(parents=True, exist_ok=True)
                length = int(self.headers.get("Content-Length") or 0)
                env = {**os.environ, "SEED": str(int(q.get("seed") or 42))}
                if length:
                    upload = d / "upload.img"
                    upload.write_bytes(self.rfile.read(length))
                    restyle = ["--restyle"] if q.get("restyle") == "1" else []
                    cmd = [str(ROOT / "make_mini.sh"), name, "--image", str(upload), *restyle, *flags]
                else:
                    desc = q.get("desc", "").strip()
                    if not desc:
                        with lock:
                            job["running"] = False
                        return self.send(400, {"error": "describe the character or add an image"})
                    cmd = [str(ROOT / "make_mini.sh"), name, desc, *flags]
            kind = path.rsplit("/", 1)[1]
            threading.Thread(target=run_job, args=(name, kind, cmd, env), daemon=True).start()
            return self.send(202, {"ok": True})

        if path in ("/api/open", "/api/reveal"):
            stl = d / f"{name}.stl"
            if not stl.exists():
                return self.send(404, {"error": "no STL yet"})
            args = ["open", "-a", "BambuStudio", str(stl)] if path == "/api/open" else ["open", "-R", str(stl)]
            subprocess.run(args, check=False)
            return self.send(200, {"ok": True})

        self.send(404, {"error": "not found"})


if __name__ == "__main__":
    RUNS.mkdir(exist_ok=True)
    print(f"Mini Forge on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
