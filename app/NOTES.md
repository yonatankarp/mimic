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

- **Swift owns everything except print prep.** `pipeline/mini_prep.py` runs inside Blender. The terminal route is `mimic make …`, the same code as the app;
  the installer links the app's binary onto the PATH.
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
- **Model files come straight from Hugging Face,** pinned to a revision, each file checked
  against its sha256; the app's check compares every file's size.
- **Children get an explicit environment,** never the app's own: launched from the Dock, the
  app has launchd's bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which lost Blender once.
- **Finding the Mimic folder:** the `installDir` default (written by the installer and by
  `bundle.sh` for the dev build), overridden by `MIMIC_HOME`. The app asks if neither works.
- **Notifications work from the self-assembled app:** `mimic --probe-notifications` inside
  the bundle reads the settings without a prompt (status 0, not yet asked).
- **Dev and release builds are different apps** (name and bundle id), so development never
  replaces the Mimic you use or shares its settings.
- **Draw Things' model is asked for, not looked up.** Its downloads are in its private
  folder, and reading that makes macOS ask for access to another app's data and block until
  answered: Settings sat on a spinner. The API's selected model comes first; the folder is a
  fallback with a 3-second limit.
- **The installer downloads the app with curl,** which doesn't set the quarantine flag, so the
  ad hoc signed app opens without Gatekeeper's warning. Signing with a Developer ID would only
  matter for downloads through a browser.

## Not yet seen working

- A notification arriving: the permission prompt is asked once after the first Make (seen:
  status went from "not asked" to "denied" on the dev app), but none has been seen delivered.
