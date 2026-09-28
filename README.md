# Mini Forge

Turn a character picture, or a description, into a print-ready STL of a tabletop
miniature. Everything runs locally on an Apple Silicon Mac.

```
picture ─┐                           ┌─ 3D mesh ─┐
         ├─ (sculpt redraw) ─ image ─┤  Pixal3D  ├─ print prep ─ STL + previews
text ────┘   FLUX.2 Klein            └───────────┘   Blender
```

1. **Image.** Your picture, optionally redrawn by FLUX.2 Klein as an unpainted grey
   sculpt of the same character. Paintings and photos mesh badly, because surface texture
   turns into bumps. With a description instead, Klein draws the character from scratch.
2. **Mesh.** [Pixal3D](https://github.com/raven38/pixal3d.cpp), through
   [image-to-3dlab](https://github.com/Bingeljell/image-to-3dlab), on the Mac's GPU.
   About 7 minutes.
3. **Print prep** (`pipeline/mini_prep.py`, Blender). About 30 seconds:
   - scales the figure to size
   - centres it on the solid cross-sections of its lower body, then fuses it to a round,
     bevelled base
   - rebuilds it as one watertight solid
   - thickens paper-thin parts, drops floating fragments, slices the bottom flat
   - exports an STL with front, side and back renders

## Setup

You need an Apple Silicon Mac, [Homebrew](https://brew.sh), full Xcode (Pixal3D compiles
Metal kernels) and about 20 GB of disk.

```bash
./setup.sh
```

This installs `uv`, `jq` and Blender, clones image-to-3dlab at the pinned release, builds
Pixal3D and downloads its weights (8.4 GB, and it asks first). Re-running it is safe.

**Draw Things** is needed for the sculpt redraw and for text-to-image. Set it up by hand:
1. Install it from the App Store and download the **FLUX.2 Klein 9B** model.
2. Settings → Advanced → **API Server**: on, **HTTP**, port **7860**.

It has to be running while you generate.

## Use

Double-click **`Mini Forge.command`**. It opens <http://127.0.0.1:8765>.

- **From image**: drop a full-body picture. Leave *Convert to a miniature sculpt first* on
  unless the picture is already a clean grey 3D render.
- **Describe it**: type the character; the seed gives different takes.
- **Character is … m tall** plus a scale (28 / 32 / 54 mm) sets the height. The height
  counts everything, horns and raised weapons included.
- **Re-prep** redoes only the print prep with new sliders, in seconds. Generation isn't
  repeated.
- **Open in Bambu Studio** / **Show in Finder**. Everything goes in `runs/<name>/`.

The same pipeline from a terminal:

```bash
./make_mini.sh dwarf-cleric "dwarf cleric, warhammer held against chest"
./make_mini.sh tiefling --image art.png --restyle --height 38
SEED=7 ./make_mini.sh dwarf-cleric-2 "dwarf cleric, warhammer held against chest"
```

Flags after the description or image go to `mini_prep.py`: `--height`, `--base`,
`--base-height`, `--inflate`, `--voxel`, `--faces`, `--no-base`, `--flatten`.

## Printing (FDM, 0.2 mm nozzle)

- Select the 0.2 mm nozzle printer preset.
- Layers: 0.06–0.08 mm.
- Supports: **Tree (auto)**.
- Stand the mini upright on its base; no brim needed.
- Walls: 3–4.

A 0.2 mm nozzle resolves details of about 0.2 mm. Finer hair strands and cloth edges get
smoothed over, but they don't cause failures.

## What limits quality

- **Small props and companions**, like a bird on a shoulder, come out as blobs. They get
  few pixels in the picture, and their hidden sides are guessed. The raw mesh already
  looks that way (`pipeline/render_zoom.py` shows it). Printing bigger helps.
  `pipeline/gen_views.py` generates the right, back and left views for Pixal3D's multiview
  mode; it isn't wired in yet.
- **Realistic proportions** shrink faces to about 4 mm at 32 mm scale. Heroic proportions
  read better, which is why the redraw asks for a slightly larger head and hands.
- **Print prep trades sharpness for printability.** `--inflate` thickens every surface.
  0.08 mm keeps cloth in one piece; 0.15 mm looked like melted clay.

## Layout

| Path | What |
|---|---|
| `make_mini.sh` | the pipeline: image → mesh → print prep |
| `pipeline/mini_prep.py` | Blender: GLB → printable STL + renders |
| `pipeline/gen_views.py` | front image → the four views for Pixal3D multiview |
| `pipeline/render_zoom.py` | close-up render for judging small details |
| `ui/` | Mini Forge web UI (`serve.py`, stdlib only; `index.html`) |
| `tests/` | `test_prep.sh` (pipeline, needs Blender) and `test_serve.py` (input checks) |
| `setup.sh` | one-time setup |
| `runs/` | generated minis (git-ignored) |
| `image-to-3dlab/` | third-party lab plus weights (git-ignored, made by `setup.sh`) |

## Tests

```bash
tests/test_prep.sh          # synthetic figure through mini_prep: watertight, flat, centred, one piece
python3 tests/test_serve.py # web UI input validation
```

## Licences

- This repository's code is yours.
- Pixal3D code and flow weights: MIT. The bundled DINOv3 encoder has its own licence.
- FLUX.2 Klein is subject to Black Forest Labs' licence. Check it before selling prints.
