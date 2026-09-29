# Working on Mimic

## Layout

| Path | What |
|---|---|
| `Install Mimic.command`, `setup.sh` | The installer. `setup.sh --yes` skips the question; `--build-from-source` compiles Pixal3D instead of downloading it (needs Xcode). |
| `app/` | The Mac app, a Swift package. `MimicCore` is everything but the windows (jobs, Draw Things, checks, the gallery on disk); `Mimic` is one binary that is the app, or the `mimic` command with arguments. `app/NOTES.md` has the design decisions and why. Print prep is `MimicCore/Prep.swift`; its header lists every tuning option (`mimic _prep in.glb out.stl …` runs it by hand). |
| `tools/package_app.sh`, `tools/package_pixal3d.sh` | Build the app and Pixal3D downloads the installer uses. |
| `runs/`, `image-to-3dlab/` | Generated minis, and the 3D engine with its models. Both are git-ignored. |

## Building and testing

```bash
cd app
swift test                         # the engine: jobs, Stop, sizes, checks, rename, Draw Things, print prep
./bundle.sh && open "build/Mimic Dev.app"
MIMIC_HOME=.. swift run mimic list # the command line, without the app
```

`bundle.sh` makes *Mimic Dev*, a separate app with its own settings, so it never replaces the
Mimic you use. Several tests plant the bug they guard against first; keep that habit when
adding one.

## Releasing a new app build

1. `tools/package_app.sh <out dir>` builds `Mimic.app`, zips it and prints its sha256.
2. Upload the zip to a GitHub release.
3. Update `MIMIC_APP_URL` and `MIMIC_APP_SHA256` in `setup.sh`.

## Releasing a new Pixal3D build

The installer downloads a pre-built Pixal3D so that nobody needs Xcode.

1. Build it as the header of `tools/package_pixal3d.sh` describes. It has to target macOS 14,
   and it has to map the source path away so your home folder doesn't end up in the files.
2. Run the script to package it.
3. Upload the tarball to a GitHub release.
4. Update `PIXAL3D_URL` and `PIXAL3D_SHA256` in `setup.sh`.
