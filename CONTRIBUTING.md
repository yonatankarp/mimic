# Working on Mimic

## Layout

| Path | What |
|---|---|
| `Install Mimic.command`, `setup.sh` | The installer. `setup.sh --yes` skips the question; `--build-from-source` compiles Pixal3D instead of downloading it (needs Xcode). |
| `Mimic.command` | Starts Mimic. The Mimic app in Applications runs it. |
| `make_mini.sh` | One mini from start to finish: picture → 3D model → print prep. |
| `pipeline/mini_prep.py` | Print prep in Blender. The comment at its top lists every tuning option. |
| `pipeline/drawthings.py` | Talks to Draw Things, always naming the model and sampler. |
| `pipeline/gen_views.py` | Experimental and unused: side and back views for Pixal3D's multiview mode. |
| `pipeline/render_zoom.py` | Close-up render, for judging small details. |
| `ui/` | The web page (`index.html`) and its server (`serve.py`). |
| `tools/package_pixal3d.sh` | Builds the Pixal3D download the installer uses. |
| `tests/` | See below. |
| `runs/`, `image-to-3dlab/` | Generated minis, and the 3D engine with its models. Both are git-ignored. |

## Tests

```bash
tests/test_prep.sh           # print prep: watertight, flat bottom, right height, centred, one piece
python3 tests/test_serve.py  # the web page's input checks
python3 tests/test_checks.py # every Settings check goes red when its part is missing, green when present
```

## Releasing a new Pixal3D build

The installer downloads a pre-built Pixal3D so that nobody needs Xcode.

1. Build it as the header of `tools/package_pixal3d.sh` describes. It has to target macOS 14,
   and it has to map the source path away so your home folder doesn't end up in the files.
2. Run the script to package it.
3. Upload the tarball to a GitHub release.
4. Update `PIXAL3D_URL` and `PIXAL3D_SHA256` in `setup.sh`.
