# Mimic for Mac: design notes

The Mac app replaced a web page and its Python server (removed once the app did everything
they did; see git history for `ui/`). Decisions below were made on measurements; read them
before changing one.

## Layout

| Part | What |
|---|---|
| `Sources/MimicCore` | Everything that isn't UI: jobs, the pipeline, Draw Things, health checks, the gallery on disk. No SwiftUI, so all of it is testable with `swift test`. |
| `Sources/Mimic` | One binary with two faces: `mimic <command>` in a terminal, the app otherwise. |
| `bundle.sh` | Assembles `Mimic Dev.app` (id `com.mimic.app.dev`) or, with `release`, `Mimic.app`. |

Build and test: `cd app && swift test && ./bundle.sh && open "build/Mimic Dev.app"`.

## Decisions

- **Swift owns everything.** The 3D engine itself is a prebuilt C++ program (`trellis-cli`);
  everything around it, and all of print prep, is this package. The terminal route is
  `mimic make …`, the same code as the app;
  Settings → Use Mimic from Terminal shows the one command that links the app's binary onto
  the PATH (`sudo`, because `/usr/local/bin` is on every Mac's PATH but a new Mac doesn't have
  it and only an administrator can make it; `~/.local/bin` needs no password but isn't on the
  PATH, which would be a second step). Through the symlink the binary reads `com.mimic.app`'s
  settings, so it finds the same install as the app.
- **Print prep is Swift, not Blender** (`MimicCore/Prep.swift`, ported from the old
  `pipeline/mini_prep.py`, whose reasons its comments keep). It runs as `mimic _prep in.glb
  out.stl [flags]`, the app's own binary started as a job step through GroupProcess, so Stop
  ends it like any other program. Measured on the dwarf (32 mm, 25 mm base, 0.2 nozzle):
  Blender 58 s and 6.0 GB (peak RSS); Swift 6 s and 1.5 GB. At 100 mm on a 0.4 nozzle:
  Blender 157 s and 13.2 GB; Swift 14 s and 2.9 GB. How:
  - The solid is a signed distance field built in slabs of grid planes, so memory follows the
    surface: a 100 mm figure at 0.1 mm is ~10⁹ grid points, never held at once. Inside is
    decided by winding along grid columns (overlapping parts union), distance exactly to the
    nearest triangle, and only near the surface. Inflate, base and the flat cut are all in the
    field, so one surface extraction makes the finished solid.
  - Marching cubes with a table generated from one rule per face (inside corners of an
    ambiguous face are always kept apart), so neighbouring cubes agree and the surface is
    closed and manifold by construction. The classic copied table leaves holes. Fans whose
    diagonal would lie on a cube face are avoided (the dwarf had 78 edges of four
    triangles from them).
  - Inflate is a true offset of the surface, not Blender's push along vertex normals: the
    uninflated dwarf comes out at 204.6 mm³ against the model's own 204.7 (Blender: 232).
  - Trimming to `--faces` is quadric edge collapse that refuses any collapse that would make
    an edge not shared by exactly two triangles.
  - Renders are drawn in software, so a child process needs no window server or GPU, and it
    doesn't compete with the 3D engine.
- **Characters and anything else.** New Mini asks what you're making. A character is exactly
  what Mimic always made. Anything else (`"kind": "object"` in settings.json, written only for
  objects, so older minis and the web version's files read as characters) gets neutral Draw
  Things prompts, no round base unless asked for, a size that is its longest side
  (`SizeCard.objectSize`, per nozzle) and print prep's `--fit longest --ground bottom`: scaled by
  its longest extent and centred on its whole shadow, where a character is centred on the
  cross-sections through its feet. Its extents come from every connected piece holding at least
  0.2% of the surface (`Mesh.mainBounds`), so a separate spout counts and a floating speck
  doesn't. A percentile of the surface, like the ground's, trimmed thin tips: a real teapot's
  spouts came out 90 mm long for 80. Prep with neither flag writes the
  same bytes as before (checked against hashes taken before the change, and by a test).
- **Same data on disk.** `runs/<name>/` with `<name>.stl`, `<name>_{front,side,back}.png`,
  `source.png` and `settings.json` (`requested` / `made` / how it was made), so minis made by
  the web version appear in the app unchanged.
- **3D viewer: RealityKit.** Measured on the dwarf's 40 MB, 2.4M-vertex print file:
  Model I/O reads the STL in 0.08 s; SceneKit builds a scene in 0.03 s (265 MB); a RealityKit
  mesh takes 0.37 s (573 MB). Both are fine; SceneKit is no longer developed, so RealityKit.
  RealityKit can't open STL, so Model I/O reads it and the triangles become a `MeshResource`,
  flat-shaded (one normal per triangle, like every slicer).
- **The 3D view turns the mini, not a camera.** RealityKit's orbit controls always zoom on
  scroll and can't be told not to, so dragging rotates the mini and a pinch zooms it once
  unlocked; Front and double-click reset that one transform. Scroll-wheel zoom isn't offered.
- **Jobs run in their own session** (`GroupProcess`, `posix_spawn` + `POSIX_SPAWN_SETSID`),
  so Stop ends the whole chain. Foundation's `Process` can't do that. Proven by
  `GroupProcessTests`, including the test that shows the child surviving without a session.
- **Step 2 is `mimic _engine`,** the app's own binary run as the job's program: it cuts the
  picture out in-process, then runs `engine/trellis-cli` as a child *in its own group*, so
  Stop's kill of the job's group ends both (`EngineTests.testStopEndsTheEngineToo`; making
  trellis-cli a session of its own fails it). It replaced image-to-3dlab's Python wrapper and
  keeps its settings: `--gss 10`, the 20° gauge camera, `PIXAL3D_STEPS=8`, a run stopped the
  moment it samples without "PIXAL3D_STEPS=8 overrides", ggml's Metal noise dropped from the
  log. Proven faithful: the wrapper's own cutout of the dwarf through `mimic _engine` gave a
  byte-identical mesh (PLY) and texture to the wrapper's run of the same build and seed. It is
  handled before the CLI finds the Mimic folder: `.job.pid` names this very
  program, and the leftover-job cleanup would otherwise stop it.
- **Cutouts: Apple Vision, not rembg or trellis-cli's BiRefNet.** Measured on the four minis'
  pictures against the u2net cutouts the Python wrapper made (`source__matted.png`): masks agree
  97.4–99.5% (IoU), and where they differ Vision is right. It kept the elf's bow tips, which
  u2net ate, and the dwarf's whole hammer head, which u2net punched a hole in. Halo-free once
  the edges' colours are pulled in from the character (`cleanEdges`, ported). 0.7 s in a
  release build. Through the whole pipeline (dwarf, seed 42) the Vision cutout gave a solid
  hammer head and no hole in the kilt where u2net's gave both; that run lost the hip satchel,
  which one seed can't pin on either cutout. So `birefnet.gguf` (0.9 GB) is no longer downloaded. Whether a picture needs
  cutting out is judged by how much of its alpha is actually clear (≥2%), not by it having
  an alpha channel: an alpha of opaque noise once became two sheets of geometry.
- **Three 3D models, chosen once per Mac** (`EngineDownload.catalogue`; 0.4.0). The same
  pinned trellis-cli runs all three; each set lives in `engine/models/<id>/`, the choice is the
  `model` default (absent = Pixal3D, so installs from before keep working with nothing to
  download), and each mini records its model in settings.json so Try Again uses it. Only sets
  proven end to end with this engine build are offered. Measured on the dwarf (seed 42, M2 Max
  32 GB, `mimic make … --model <id>` through the app's own `_engine` and `_prep`):

  | Model | Download | Flows (sum) | Whole mini | Max RSS of any step |
  |---|---|---|---|---|
  | Pixal3D (`pixal3d-sv`, default) | 8.1 GB | 5.5 min | 7.5 min | 5.1 GB |
  | TRELLIS.2 (`trellis2-q8`) | 9.1 GB | 11.5 min | 13.5 min | 6.9 GB |
  | TRELLIS.2 Lite (`trellis2-q4`) | 5.7 GB | 9.7 min | 12.3 min | 8.1 GB |

  (`/usr/bin/time -l` on `mimic make`: its RSS is the largest step it waited for, so the
  Lite figure isn't the engine's alone.) TRELLIS.2's high-resolution shape pass is the
  difference: 13,600 tokens, 5–6 minutes, against Pixal3D's 2.8. One picture and one seed,
  so the look below is a first impression, not a ranking. Look: Pixal3D has the sharpest face and rivets; both TRELLIS.2 sets
  put the hammer on the shoulder where the picture has it, where Pixal3D pushed it out towards
  the viewer (see the side renders), and q4 is hard to tell from q8. TRELLIS.2 runs the plain
  one-picture pipeline at its own defaults (`--image … --output …`: a lone positional after
  `--image` is read as a second picture; `--gss 10` was tuned on Pixal3D only), and writes its
  figure facing away, so print prep turns it round (`--turn 180`, `EngineModel.turn`).
  `PIXAL3D_STEPS=8` applies to every flow of both pipelines, so one guard covers both.
  Rejected: Pixal3D's multiview set (`raven38/pixal3d-q8_0-v1`) wants four pictures of the
  figure; `--trellis2-mv` wants 2–8; TRELLIS.2 at full precision is 15.5 GB. The TRELLIS.2 sets
  come from `ilintar/trellis2-gguf` (TRELLIS.2 is MIT) without its birefnet.gguf (Mimic always
  hands over a cutout); that repository ships no licence files, so every set takes
  raven38's `MIT_LICENSE.md` and `DINOV3_LICENSE.md`, which the DINOv3 Agreement requires to
  travel with dinov3.gguf. Four TRELLIS.2 q8 files are byte for byte Pixal3D's (2.2 GB): setup
  clones them (APFS `clonefile`) instead of downloading, and Remove counts them as freeing
  nothing while their twin stays.
- **Model files come straight from Hugging Face,** pinned to a revision, each file checked
  against its sha256; the app's check compares every file's size.
- **Children get an explicit environment,** never the app's own: launched from the Dock, the
  app has launchd's bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which lost Blender once.
- **Where things live (the disk image has no Mimic folder):** minis in `~/Documents/Mimic`,
  where people look for their files; the engine and its models (5.7–9.1 GB) in
  `~/Library/Application Support/Mimic/engine`, out of their way (and out of Documents, which
  iCloud may sync). `Install` keeps the two separate. An install made by the old `setup.sh` has
  one folder with `runs/` and `engine/` inside, stored as the `installDir` default: that still
  wins while the folder exists, and `MIMIC_HOME` beats both for development and tests.
  `Install.locate` always answers; a missing engine is setup's job, not a "not installed" screen.
  The first launch shows the one-time ~/Documents permission prompt macOS asks of every app.
- **First launch sets itself up** (`EngineDownload.swift`, ported from `setup.sh`): the pinned
  engine tarball and Hugging Face files, each with its size and sha256 in one manifest that the
  health check also reads. Downloads go to `<name>.part` and resume with HTTP Range (checked
  against a local server that logs the Range asked for and the bytes served: a re-download
  would end with the same sha256); a finished file with the wrong sha256 is deleted so Try
  Again starts it afresh; files already right are hashed and kept. It runs in the app, so
  closing the window doesn't stop it (the app stays open while it runs). An old install's
  `image-to-3dlab/vendor/pixal3d-cpp` is moved, never downloaded again, starts automatically at
  launch, and image-to-3dlab is removed only after every move succeeded; the pass after it
  checks every moved file's sha256. Settings offers Download / Repair on the two engine checks;
  the engine check also wants the pinned `VERSION`, so a new engine pin shows up as Repair.
  `MIMIC_FAKE_HOME` (a new Mac's home folder, `installDir` ignored) and `MIMIC_DOWNLOAD_MIRROR`
  (a local server instead of the internet) are for trying it.
- **Notifications work from the self-assembled app:** `mimic --probe-notifications` inside
  the bundle reads the settings without a prompt (status 0, not yet asked).
- **Dev and release builds are different apps** (name and bundle id), so development never
  replaces the Mimic you use or shares its settings.
- **Draw Things' model is asked for, not looked up.** Its downloads are in its private
  folder, and reading that makes macOS ask for access to another app's data and block until
  answered: Settings sat on a spinner. The API's selected model comes first; the folder is a
  fallback with a 3-second limit.
- **The first-run tour is popovers on the real controls** (`Sources/Mimic/TourGuide.swift`;
  when it starts and what comes next is `MimicCore/Tour.swift`, tested). Anchor preferences
  can't reach the toolbar or the New Mini sheet, which are hosted apart from the window's
  content; a popover can, and never covers what it points at. `interactiveDismissDisabled`
  keeps one up while you click around (without it a click anywhere ended the tour); Skip and
  Esc end it, and a stop whose control isn't on screen (no mini yet) is skipped. The sample
  picture ships in SwiftPM's `Mimic_Mimic.bundle`, which `bundle.sh` copies into
  Contents/Resources; it's looked up by hand, not through `Bundle.module`, whose accessor
  stops the app when the bundle is missing. Seen once: Help → Show Tour replays it.
- **Self-signed, by decision.** The disk image is downloaded through a browser, so macOS
  quarantines it and the first open needs System Settings → Privacy & Security → Open Anyway,
  once; the README and a note in the disk image say so. A Developer ID would remove that step.

## Not yet seen working

- Setup's full 8.1 GB download through the app, and closing the window mid-download: the
  download path is proven by tests against a local server and by a real run of the engine and
  the small files; the window close is `applicationShouldTerminateAfterLastWindowClosed`, and
  before it closing the setup window quit Mimic (seen).

- A notification arriving: the permission prompt is asked once after the first Make (seen:
  status went from "not asked" to "denied" on the dev app), but none has been seen delivered.
