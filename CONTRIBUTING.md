# Working on Mimic

## Layout

| Path | What |
|---|---|
| `app/` | The Mac app, a Swift package. `MimicCore` is everything but the windows (jobs, Draw Things, checks, the gallery on disk); `Mimic` is one binary that is the app, or the `mimic` command with arguments. `app/NOTES.md` has the design decisions and why. Print prep is `MimicCore/Prep.swift`; its header lists every tuning option (`mimic _prep in.glb out.stl …` runs it by hand). |
| `tools/package_dmg.sh` | Builds `Mimic.app` into the disk image a release publishes. |
| `tools/package_pixal3d.sh`, `tools/pixal3d-steps.patch` | Package the Pixal3D build the app downloads on first launch. |
| `.github/workflows/release.yml` | Tests every change, builds the disk image, and publishes a release from a version tag. |
| `runs/`, `engine/` | The dev build's minis and 3D engine (`trellis-cli`, models in `engine/models/pixal3d-sv/`), when this checkout is its Mimic folder. Both are git-ignored. An installed Mimic keeps them in `~/Documents/Mimic` and `~/Library/Application Support/Mimic/engine` instead; `app/NOTES.md` says how it chooses. |

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

## Trying first launch

Setup needs no terminal, so try it the way a new Mac sees it, without touching your own Mimic:

```bash
MIMIC_FAKE_HOME=/tmp/newmac "build/Mimic Dev.app/Contents/MacOS/mimic"
```

`MIMIC_FAKE_HOME` treats that folder as the home folder of a Mac that has never run Mimic.
`MIMIC_DOWNLOAD_MIRROR=http://127.0.0.1:8000` downloads from a local server holding the
files (by name) instead of the internet. `swift test` covers the downloads against a local
server; `MIMIC_NETWORK_TEST=/tmp/newmac swift test --filter testRealDownloadOfTheSmallFiles`
downloads the real engine and the small model files, never the 8 GB of weights.

## Releasing

1. Add a `## 0.3.0` section to `CHANGELOG.md`, written for people who use Mimic. It becomes the
   release notes; a tag without one fails before anything is published.
2. Push a version tag:

   ```bash
   git tag v0.3.0 && git push origin v0.3.0
   ```

The workflow tests, builds `Mimic-0.3.0.dmg` and publishes it as a GitHub release with that
section as its notes. The README's install steps link to the latest release, so nothing else
needs updating.

## Releasing a new Pixal3D build

The app downloads a pre-built Pixal3D so that nobody needs Xcode.

1. Build it as the header of `tools/package_pixal3d.sh` describes. It has to target macOS 14,
   and it has to map the source path away so your home folder doesn't end up in the files.
   It also has to honour `PIXAL3D_STEPS` (its log says "PIXAL3D_STEPS=8 overrides 12 steps"):
   stock pixal3d.cpp ignores it, and Mimic stops any run whose engine does. Apply
   `tools/pixal3d-steps.patch` to the pixal3d.cpp checkout first (`git apply`); it's the change
   image-to-3dlab's `scripts/patch_pixal3d_steps.py` made (Apache-2.0), kept here since Mimic
   no longer uses image-to-3dlab.
2. Run the script to package it.
3. Upload the tarball to a GitHub release.
4. Update `EngineDownload.version` and `EngineDownload.engine` (URL, size, sha256) in
   `app/Sources/MimicCore/EngineDownload.swift`. Installed copies replace an engine whose
   `VERSION` doesn't match the next time setup runs (Settings → Repair).
