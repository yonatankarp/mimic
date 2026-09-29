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

- **Swift owns everything except two Python pieces.** The 3D engine's wrapper
  (image-to-3dlab's `pixal3d_generate.py`, third-party) and `pipeline/mini_prep.py` (it runs
  inside Blender) stay Python. The terminal route is `mimic make …`, the same code as the app;
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
