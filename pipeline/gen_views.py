"""Front image -> the four framed RGBA views Pixal3D multiview expects.

    image-to-3dlab/.venv/bin/python pipeline/gen_views.py front.png out_dir [--seed 42]

FLUX.2 Klein (Draw Things, edit mode at strength 1) redraws the character from the
right, back and left. Every view is then matted and put on the same square canvas at
the same scale: the canonical rig is front/right/back/left at azimuth 0/90/180/270,
elevation 0, FOV 20 degrees, where the unit cube fills ~91% of the frame.

Which side is which, from the camera matrices in pixal3d.cpp's canonical rig:
"right" is the camera moved 90 degrees to the right, so it sees the side that was on
the right of the front image, and the figure faces the image's left edge.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image

LAB = Path(__file__).resolve().parents[1] / "image-to-3dlab"
sys.path[:0] = [str(LAB), str(Path(__file__).resolve().parent)]
from image_to_3dlab.matte import cut_out  # noqa: E402
import drawthings  # noqa: E402  (beside this file)

CANVAS = 1024
FILL = 0.85  # figure height as a share of the frame, the README's advice for this rig

COMMON = ("Show this exact same miniature sculpt from a different angle: {turn}. Same "
          "character, same pose, same proportions, same clothing and accessories, the "
          "whole figure visible head to feet at the same size, camera level with the "
          "figure's chest, straight-on with no tilt, plain light grey studio background, "
          "soft even lighting, unpainted grey 3D render.")
TURNS = {
    "right": "the camera has orbited 90 degrees to the right, so we see a strict side "
             "profile with the figure facing the LEFT edge of the image; the side that was "
             "on the right of the original image is now nearest the camera",
    "back": "the camera has orbited 180 degrees, so we see the figure directly from "
            "behind; everything that was on the right of the original image is now on "
            "the left",
    "left": "the camera has orbited 90 degrees to the left, so we see a strict side "
            "profile with the figure facing the RIGHT edge of the image; the side that "
            "was on the left of the original image is now nearest the camera",
}
ORDER = ["front", "right", "back", "left"]


def frame(cut: Image.Image) -> Image.Image:
    """Same scale in every view: height is unchanged by a turn about the vertical axis,
    so scaling each figure to FILL of the frame height gives all four one scale factor.
    Centred on the body axis (the lower body), not the bounding box, which a book or a
    bird on one shoulder would pull sideways in the profile views."""
    alpha = cut.getchannel("A").point(lambda v: 255 if v > 127 else 0)
    x0, y0, x1, y1 = alpha.getbbox()
    fig = cut.crop((x0, y0, x1, y1))
    s = FILL * CANVAS / fig.height
    fig = fig.resize((max(1, round(fig.width * s)), round(fig.height * s)), Image.LANCZOS)
    a = fig.getchannel("A")
    lower = a.crop((0, int(a.height * 0.6), a.width, a.height))
    cols = [sum(1 for y in range(0, lower.height, 4) if lower.getpixel((x, y)) > 127)
            for x in range(lower.width)]
    total = sum(cols) or 1
    axis = sum(x * c for x, c in enumerate(cols)) / total
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(fig, (round(CANVAS / 2 - axis), round((CANVAS - fig.height) / 2)), fig)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("front", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--only", choices=ORDER, nargs="*", help="redo just these views")
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    front = Image.open(a.front).convert("RGB")
    for i, name in enumerate(ORDER, 1):
        if a.only and name not in a.only:
            continue
        print(f"view {i}/4: {name}", flush=True)
        img = front if name == "front" else drawthings.edit(front, COMMON.format(turn=TURNS[name]), a.seed)
        img.save(a.out / f"raw_{name}.png")
        cut, _ = cut_out(img)
        frame(cut).save(a.out / f"{i}_{name}.png")
    # Contact sheet for a human (and the UI) to check before spending minutes meshing.
    sheet = Image.new("RGB", (4 * 384, 384), (40, 40, 40))
    for i, name in enumerate(ORDER):
        v = Image.open(a.out / f"{i + 1}_{name}.png").resize((384, 384))
        sheet.paste(v, (i * 384, 0), v)
    sheet.save(a.out / "sheet.png")
    print(f"views in {a.out}")


if __name__ == "__main__":
    main()
