"""Draw Things' HTTP API: the one place that knows its address, model and settings.

    python pipeline/drawthings.py txt2img --prompt "..." --seed 42 --out source.png
    python pipeline/drawthings.py edit --image art.png --prompt "..." --seed 42 --out source.png
    python pipeline/drawthings.py status

Every request names its model and sampler. Left out, the API renders with whatever the
app happens to have selected: a user with SDXL selected got plain text-to-image at
strength 1, which ignores their picture completely and raises no error.
"""

import argparse
import base64
import io
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

API = os.environ.get("DRAWTHINGS_URL", "http://127.0.0.1:7860")
MODELS_DIR = Path.home() / "Library/Containers/com.liuliu.draw-things/Data/Documents/Models"

# FLUX.2 Klein is step-distilled; these are the settings it was made for, and the ones
# every image in this project was generated with.
SETTINGS = {
    "steps": 4, "sampler": "DDIM Trailing", "guidance_scale": 1.0, "shift": 3.0,
    "resolution_dependent_shift": False, "seed_mode": "Scale Alike",
    "loras": [], "controls": [], "refiner_model": None,
}
NOT_RUNNING = ("Draw Things isn't answering on {api}. Open Draw Things, then Settings → "
               "Advanced → API Server: turn it on, HTTP, port 7860.")
NO_MODEL = ("FLUX.2 Klein isn't downloaded in Draw Things. In Draw Things, open the model "
            "list, search 'FLUX.2 Klein', and download it (the 9B one if it fits, else 4B).")


def find_model() -> str | None:
    """The Klein checkpoint to ask for: DRAWTHINGS_MODEL, else the largest one downloaded."""
    if os.environ.get("DRAWTHINGS_MODEL"):
        return os.environ["DRAWTHINGS_MODEL"]
    hits = sorted(p.name for p in MODELS_DIR.glob("flux_2_klein*.ckpt")) if MODELS_DIR.is_dir() else []
    return hits[-1] if hits else None  # "9b" sorts after "4b"


def reachable(timeout: float = 1.5) -> bool:
    try:
        with urllib.request.urlopen(f"{API}/sdapi/v1/options", timeout=timeout):
            return True
    except (OSError, urllib.error.URLError):
        return False


def _post(path: str, body: dict):
    from PIL import Image

    model = find_model()
    if not model:
        raise SystemExit(NO_MODEL)
    req = urllib.request.Request(f"{API}{path}", json.dumps({**SETTINGS, "model": model, **body}).encode(),
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Draw Things refused the request: {e.read()[:300].decode(errors='replace')}")
    except (OSError, urllib.error.URLError):
        raise SystemExit(NOT_RUNNING.format(api=API))
    return Image.open(io.BytesIO(base64.b64decode(data["images"][0]))).convert("RGB")


def txt2img(prompt: str, seed: int, size=(1024, 1024)):
    return _post("/sdapi/v1/txt2img", {"prompt": prompt, "seed": seed, "width": size[0], "height": size[1]})


def edit(image, prompt: str, seed: int):
    """Klein at strength 1 is an editor: it redraws the picture as the prompt says.
    Draw Things wants width/height equal to the image's, in multiples of 64."""
    from PIL import Image

    s = 1536 / max(image.size)
    w, h = (max(64, round(v * s / 64) * 64) for v in image.size)
    image = image.convert("RGB").resize((w, h), Image.LANCZOS)
    buf = io.BytesIO()
    image.save(buf, "PNG")
    return _post("/sdapi/v1/img2img", {"init_images": [base64.b64encode(buf.getvalue()).decode()],
                                        "strength": 1.0, "prompt": prompt, "seed": seed,
                                        "width": w, "height": h})


def main():
    from PIL import Image

    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("txt2img")
    e = sub.add_parser("edit")
    e.add_argument("--image", type=Path, required=True)
    for q in (t, e):
        q.add_argument("--prompt", required=True)
        q.add_argument("--seed", type=int, default=42)
        q.add_argument("--out", type=Path, required=True)
    sub.add_parser("status")
    a = p.parse_args()
    if a.cmd == "status":
        print(json.dumps({"reachable": reachable(), "model": find_model()}))
        return
    if not reachable():
        sys.exit(NOT_RUNNING.format(api=API))
    img = txt2img(a.prompt, a.seed) if a.cmd == "txt2img" else edit(Image.open(a.image), a.prompt, a.seed)
    img.save(a.out)


if __name__ == "__main__":
    main()
