#!/usr/bin/env python3
"""Mimic: a local web UI over make_mini.sh and mini_prep.py.

    image-to-3dlab/.venv/bin/python ui/serve.py      # or double-click Mimic.command

Stdlib only. One job at a time: Pixal3D and Blender both want the whole machine.
"""

import json
import math
import os
import re
import shutil
import subprocess
import sys
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
TYPES = {".html": "text/html; charset=utf-8", ".png": "image/png", ".stl": "model/stl", ".svg": "image/svg+xml",
         ".glb": "model/gltf-binary", ".json": "application/json", ".log": "text/plain; charset=utf-8"}

# Started from the Mimic app, the server gets launchd's PATH (/usr/bin:/bin:/usr/sbin:/sbin),
# where neither Homebrew's tools nor Blender are, so every mini failed at print prep.
os.environ["PATH"] = os.pathsep.join(
    ["/opt/homebrew/bin", "/Applications/Blender.app/Contents/MacOS", os.environ.get("PATH", "/usr/bin:/bin")])
LAB = ROOT / "image-to-3dlab"
ENGINE = LAB / "vendor" / "pixal3d-cpp"
APP_DIRS = [Path("/Applications"), Path.home() / "Applications"]
# Slicers Mimic can hand a mini to: shown name -> the bundle names it ships under.
SLICERS = {
    "bambu": ("Bambu Studio", ["BambuStudio.app", "Bambu Studio.app"]),
    "orca": ("OrcaSlicer", ["OrcaSlicer.app"]),
    "prusa": ("PrusaSlicer", ["PrusaSlicer.app", "Original Prusa Drivers/PrusaSlicer.app"]),
    "cura": ("UltiMaker Cura", ["UltiMaker Cura.app", "Ultimaker Cura.app", "Ultimaker-Cura.app"]),
    "creality": ("Creality Print", ["Creality Print.app", "CrealityPrint.app"]),
    "elegoo": ("ElegooSlicer", ["ElegooSlicer.app"]),
    "anycubic": ("Anycubic Slicer Next", ["AnycubicSlicerNext.app", "Anycubic Slicer Next.app"]),
    "super": ("SuperSlicer", ["SuperSlicer.app"]),
    "ideamaker": ("ideaMaker", ["ideaMaker.app"]),
    "flashprint": ("FlashPrint", ["FlashPrint 5.app", "FlashPrint.app"]),
    "simplify": ("Simplify3D", ["Simplify3D.app", "Simplify3D 5.app"]),
    "lychee": ("Lychee Slicer", ["Lychee Slicer.app", "LycheeSlicer.app"]),
    "chitubox": ("CHITUBOX", ["CHITUBOX Basic.app", "CHITUBOX.app"]),
}

NOZZLES = {"0.2", "0.4", "0.6"}
STATIC = {"/logo.png"}  # served from ui/ as they are

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
    if "nozzle" in q:
        if q["nozzle"] not in NOZZLES:
            raise ValueError("nozzle")
        flags += ["--nozzle", q["nozzle"]]
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


def health():
    """What the page's setup checklist shows. Draw Things is only needed to draw or redraw
    a picture; turning an existing picture into a mini works without it."""
    sys.path.insert(0, str(ROOT / "pipeline"))
    import drawthings  # stdlib-only at import time

    return {"drawthings": {"running": drawthings.reachable(), "model": drawthings.find_model() is not None}}


def installed_slicers():
    """{id: (name, path)} for every known slicer present in an Applications folder."""
    found = {}
    for key, (name, bundles) in SLICERS.items():
        for d in APP_DIRS:
            hit = next((d / b for b in bundles if (d / b).is_dir()), None)
            if hit:
                found[key] = (name, str(hit))
                break
    return found


def engine_starts():
    """Whether the 3D engine launches. Run fresh every time (it takes ~10 ms): a cached
    answer is how a check keeps saying yes after the thing it checks has gone."""
    cli = ENGINE / "build" / "trellis-cli"
    try:
        return cli.is_file() and subprocess.run([str(cli), "--help"], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


REINSTALL = "Run Install Mimic again: it only adds what's missing."


def _free_gb():
    return shutil.disk_usage(RUNS).free / 1e9


# Everything Mimic depends on: (id, label, required, test, fix). `required` ones stop it
# working; the rest only switch off a feature (drawing pictures, opening a slicer). Tests are
# functions so the page can run them one at a time and show each result as it arrives.
CHECKS = [
    ("engine", "3D engine", True, lambda: engine_starts(), REINSTALL),
    ("models", "3D model files", True,
     lambda: (ENGINE / "models" / "pixal3d-sv" / "pixal3d_shape_flow_1024_sv.gguf").is_file(),
     REINSTALL + " This part downloads 8.4 GB."),
    ("helpers", "Mimic's helper tools", True, lambda: (LAB / ".venv" / "bin" / "python").is_file(), REINSTALL),
    ("blender", "Blender (makes the print file)", True, lambda: shutil.which("blender") is not None,
     "Install Blender from blender.org, or run Install Mimic again."),
    ("space", "Free disk space", True, lambda: _free_gb() >= 5,
     "Free up some space: each mini takes about 150 MB while it's being made."),
    ("drawthings-app", "Draw Things app", False,
     lambda: any((d / "Draw Things.app").is_dir() for d in APP_DIRS),
     "Install Draw Things from the Mac App Store. It's free."),
    ("drawthings-api", "Draw Things is open and connected", False, lambda: health()["drawthings"]["running"],
     "Open Draw Things, then Settings → Advanced → API Server: turn it on, choose HTTP, port 7860."),
    ("drawthings-model", "FLUX.2 Klein model in Draw Things", False, lambda: health()["drawthings"]["model"],
     "In Draw Things' model list, search for FLUX.2 Klein and download it."),
    ("slicer", "A slicer to print with", False, lambda: bool(installed_slicers()),
     "Install a slicer such as Bambu Studio, OrcaSlicer, PrusaSlicer or Cura. "
     "Until then Mimic opens minis with your Mac's default app for 3D files."),
]


def run_check(check_id):
    """Run one check; None for an unknown id."""
    for i, label, required, test, fix in CHECKS:
        if i == check_id:
            if i == "space":
                label = f"{label} ({_free_gb():.0f} GB)"
            return {"id": i, "label": label, "required": required, "ok": bool(test()), "fix": fix}
    return None


def checks():
    return [run_check(i) for i, *_ in CHECKS]


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
        if path == "/api/health":
            return self.send(200, health())
        if path == "/api/checks":
            # The list only, nothing run yet: the page shows a spinner per row, then asks
            # /api/check for each in turn.
            return self.send(200, {"checks": [{"id": i, "label": l, "required": r} for i, l, r, *_ in CHECKS],
                                   "slicers": [{"id": k, "name": n} for k, (n, _) in installed_slicers().items()],
                                   "runs_dir": str(RUNS)})
        if path == "/api/check":
            result = run_check(self.query().get("id", ""))
            return self.send(200, result) if result else self.send(404, {"error": "no such check"})
        if path in STATIC and (UI / path[1:]).is_file():
            return self.send_file(UI / path[1:])
        m = re.match(r"^/runs/([a-z0-9-]+)/([A-Za-z0-9_.-]+)$", path)
        if m:
            f = (RUNS / m[1] / m[2]).resolve()
            if f.is_relative_to(RUNS.resolve()) and f.is_file():
                return self.send_file(f)
        self.send(404, {"error": "not found"})

    def do_POST(self):
        path, q = urlparse(self.path).path, self.query()
        if path == "/api/reveal-folder":
            RUNS.mkdir(exist_ok=True)
            subprocess.run(["open", str(RUNS)], check=False)
            return self.send(200, {"ok": True})
        if path == "/api/quit":
            with lock:
                if job["running"]:
                    return self.send(409, {"error": f"still making {job['name']}"})
            self.send(200, {"ok": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
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
            if path == "/api/reveal":
                args = ["open", "-R", str(stl)]
            elif q.get("app", "default") == "default":
                args = ["open", str(stl)]  # whatever the Mac opens .stl files with
            else:
                slicer = installed_slicers().get(q["app"])
                if not slicer:
                    return self.send(404, {"error": "slicer not installed"})
                args = ["open", "-a", slicer[1], str(stl)]
            subprocess.run(args, check=False)
            return self.send(200, {"ok": True})

        if path == "/api/delete":
            with lock:
                if job["running"] and job["name"] == name:
                    return self.send(409, {"error": f"still making {name}"})
            if not d.is_dir():
                return self.send(404, {"error": "not found"})
            # To the Trash, not gone: a wrong click is one drag back from the Trash.
            done = subprocess.run(["/usr/bin/trash", str(d)], capture_output=True)
            if done.returncode:
                return self.send(500, {"error": "couldn't move it to the Trash"})
            return self.send(200, {"ok": True})

        self.send(404, {"error": "not found"})


if __name__ == "__main__":
    RUNS.mkdir(exist_ok=True)
    print(f"Mimic on http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
