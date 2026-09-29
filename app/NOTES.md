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

- **Swift owns everything except the 3D engine's wrapper** (image-to-3dlab's
  `pixal3d_generate.py`, third-party). The terminal route is `mimic make …`, the same code as
  the app; the installer links the app's binary onto the PATH.
- **Print prep is Swift, not Blender** (`MimicCore/Prep.swift`, ported from the old
  `pipeline/mini_prep.py`, whose reasons its comments keep). It runs as `mimic _prep in.glb
  out.stl [flags]`, the app's own binary started as a job step through GroupProcess, so Stop
  ends it like any other program. Measured on the dwarf (32 mm, 25 mm base, 0.2 nozzle):
  Blender 58 s and 6.0 GB (peak RSS); Swift about 9 s and 1.5 GB. At 100 mm on a 0.4 nozzle:
  Blender 157 s and 13.2 GB; Swift about 19 s and 2.9 GB. How:
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
