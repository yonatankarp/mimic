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
  - **Pieces print prep leaves out** (#17). Only the largest connected piece is kept, and the
    rest are of two kinds, told apart by the sign of their volume, not their size. The inner
    wall of a hollow is a piece of its own, inside out, so its volume is negative: dropping it
    fills the hollow, and these are the big ones (the elf's was 575 mm³ and its whole body's
    length; the tieflings' up to 234 mm³ and 29% of the height). A solid dropped piece is
    either a speck or a held thing the generator didn't join to the hands, and a solid piece
    whose longest side is at least 10% of the height is the second: it's still left out, but
    prep prints `mini_prep: WARNING part: <what to tell the person>`, which the mini's page,
    the progress window and `mimic make` show as it is. Measured on the seven minis in the
    gallery at their own sizes: the Pixal3D elf's bow was 30 mm long (93% of 32 mm) and
    54 mm³; the largest solid speck on any of them was 0.93 mm (0.93% of 100 mm) and 0.001
    mm³. The 10% leaves an order of magnitude either side. `testRealMinisWarnOnlyOfARealPart`
    reruns that on a folder of model.glb files (`MIMIC_PREP_MINIS`). The part is left out
    rather than kept as a second body in the STL: slicers print several bodies, but this one
    floats where the hands held it, so it prints as a loose piece needing supports and glue,
    not as held. Make Another Version or TRELLIS.2 (which joined the bow on every seed, #2)
    is the fix, so that's what the warning says.
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
- **Projects are real folders, one level deep** (`MimicCore/Gallery.swift`, `Projects.swift`;
  0.5.0): `runs/<Project>/<mini>/`, so Finder shows the same grouping. A folder is a mini when it
  holds `settings.json` (every mini since the web version, written the moment one is asked
  for), `model.glb` (older minis without settings: `tiefling-sculpt` on the Mac this was built
  on) or a print file named after the folder, never just any `.stl` (one dragged into a project
  in Finder would turn the project into a mini). Any other folder at the top is a project, empty
  ones included; inside a project only minis count, since projects don't nest. `_` and `.`
  folders and files at the top (`.queue.json`, `.job.*`) are never either, so a folder from
  before projects reads exactly as it did. `make` writes settings.json before the picture, and
  removes the folder it made if either fails, so a failed request never leaves an empty folder
  that would read as a project. Names stay unique across the whole minis folder, projects
  included and compared without case (the Mac's disk sees "Orcs" and "orcs" as one folder), so
  everything that names a mini (the queue, `mimic resize <name>`, rename, trash, time
  estimates) finds it with `Gallery.folder(runs, name)`; queue entries are still just names, so
  queue files from before read unchanged. Moving a mini, renaming a project and deleting one
  happen under the queue's lock, where a job finds its folder as it starts: a mini being made or
  waiting can't be moved, a project can't be renamed while one of its minis is being made (its
  steps hold the folder's path; waiting ones are found by name when they start), and a project
  with one of either can't be deleted. Deleting keeps the minis by default (moved to Unsorted);
  the project's folder goes to the Trash either way, never removed, since it may hold files of
  the person's own.
- **Make Another Version** (`MimicCore/Versions.swift`) is `make` with the mini's own saved
  source and settings and a new random seed (1–999,999, never the old one; absent means 42),
  named `<name>-2`, then the next number free anywhere (`raven-2` → `raven-3`; a suffix of 1000
  or more is a year, not a version), in the same project. The seed is what step 1 draws a
  description or the grey sculpt from and what `_engine --seed` hands trellis-cli, so a new one
  changes the shape even when the picture is reused unchanged (a picture without the sculpt).
  The issue this came from: the tiefling wizard's raven was a blob at seeds 42 and 1234 and a
  folded wing at 7. A picture mini from before `upload.img` was kept has only source.png, which
  is what its 3D step saw, so that is used without the sculpt; a mini with no settings can't be
  made again and the menu item is off.
- **Same data on disk.** `runs/<name>/` (or `runs/<project>/<name>/`) with `<name>.stl`, `<name>_{front,side,back}.png`,
- **An object that can't stand is set on a side it can** (`Mesh.rest`, `MimicCore/Rest.swift`),
  after levelling. Its sides are the faces of its convex hull (quickhull over one point per
  1/256 grid cell of the main pieces, so floating specks don't hold it up), a side being the hull
  faces lying flat together within 3°. Counting every point near the floor instead made a round
  body a small flat disc, and every real model "stood" at every angle. It stands on a side if it
  survives an 8° tilt there: atan(r/h), r from its centre of mass (the volume centroid when the
  surface closes, else the area centroid, since the generator's winding isn't reliable) in to the
  side's nearest edge, h its height. Measured on real models, after levelling: bases 13–26°
  (teapot2, vase, teapot, and figures run as objects down to the elf on its feet at 8.4°); the
  teapots and the vase on their sides or upside down, nothing within 30° of down above 6.1°. A
  box 4 or 6 times as tall as wide stands (14°, 9.5°), 8 times (7.1°) is laid down. Standing on
  a side within 10° of down, it is left alone however much steadier lying would be: a vase, a
  pillar or a statue with a flat back is never laid down, so "much more stable elsewhere" is
  deliberately not a reason. Otherwise it goes onto the steadiest side (most lift,
  sqrt(r² + h²) − h, to tip it; nearest to down on a tie) within 30° of down, else of all. It
  runs after levelling and nothing levels after it: the side's facing is already exact. The
  real teapot had been levelled 2.8° onto the edge of its foot and printed 20° askew; it now
  stands on its foot. teapot2, the vase and every character give the same bytes as before;
  turned 90° either way or 180°, the teapots and the vase came back upright on their bases,
  except the vase upside down, which stands on its mouth's rim (9.2°) and so stays. 0.3–0.5 s
  for a million triangles in a release build. Limits: a figure that only stands on a base (the
  halfling bard and a tiefling, centre of mass outside their feet) is laid down if made as an
  object, and so is one with a thin part hanging below its base (the test fixture's wisp).
  Characters never go through this.
- **Same data on disk.** `runs/<name>/` with `<name>.stl`, `<name>_{front,side,back}.png`,
  `source.png` and `settings.json` (`requested` / `made` / how it was made), so minis made by
  the web version appear in the app unchanged.
- **3D viewer: RealityKit.** Measured on the dwarf's 40 MB, 2.4M-vertex print file:
  Model I/O reads the STL in 0.08 s; SceneKit builds a scene in 0.03 s (265 MB); a RealityKit
  mesh takes 0.37 s (573 MB). Both are fine; SceneKit is no longer developed, so RealityKit.
  RealityKit can't open STL, so Model I/O reads it and the triangles become a `MeshResource`,
  flat-shaded (one normal per triangle, like every slicer).
- **The 3D view turns the mini, not a camera.** Dragging rotates the mini; a pinch, a
  trackpad scroll or a mouse wheel zooms it toward the pointer (the maths is
  `MimicCore/ViewerZoom.swift`, tested); Face Front and double-click reset turn, zoom and offset.
  Zoom listens to the window's pinch and scroll events while the pointer is over the view:
  a SwiftUI MagnifyGesture never fired, because the 3D view kept pinches to itself.
- **The 3D view draws only when something changes.** SwiftUI's `RealityView` redraws every
  display frame and has no public way to pause, which cost about 20% of a core with a mini just
  standing there. `RealityRenderer` (public, macOS 15) drawing into a paused Metal view redraws
  on a turn, zoom, resize or new mini, and every frame only while a glide plays: about 1% of a
  core idle in front, 0% behind. It has no default ambient light, so it carries its own grey
  studio light, matched to the old look by brightness.
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
- **TRELLIS.2 is the default; Lite is gone** (0.6.0, [#2](https://github.com/yonatankarp/mimic/issues/2)).
  The table above is the 0.4.0 measurement, kept as history. #2 ran pictures with something
  held or attached (the dwarf's hammer and shield, the elf's bow, the halfling's lute, the
  tiefling's raven) through the models with several seeds, judged from the side and back
  renders: TRELLIS.2 had the held part right 9 times out of 9, Pixal3D 4 out of 10 (bows lost
  when not joined to the hands, the raven a blob from behind, the hammer pushed out in front).
  Pixal3D keeps the crispest surface and is faster on bulky figures, so it stays as the second
  choice. TRELLIS.2 Lite lost the elf's bow and was no faster than TRELLIS.2, so it was removed.
  A mini or install with no model recorded now means TRELLIS.2 (alpha: no compatibility kept).
- **Model files come straight from Hugging Face,** pinned to a revision, each file checked
  against its sha256; the app's check compares every file's size.
- **Children get an explicit environment,** never the app's own: launched from the Dock, the
  app has launchd's bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which lost Blender once.
- **Where things live (the disk image has no Mimic folder):** minis in `~/Documents/Mimic`,
  where people look for their files; the engine and its models (8.1–9.1 GB) in
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
- **`draw-things-cli` comes first** (`DrawThings.cli`): Mimic's own copy in `engine/`, pinned
  by sha256 in `EngineDownload.drawThingsCLI` and downloaded by setup like the engine (an
  install without it goes back to setup for it). PATH is never searched. With it, a picture
  is a subprocess (`generate`; the pinned release only generates locally and refuses `--local`,
  while newer builds may use Draw Things' cloud without it, so check that when re-pinning), the app
  never opens, and the API server doesn't matter: the API check is green. Stop terminates it.
  The API is only the fallback when the tool isn't installed, not a retry when it fails.
- **Without it, Mimic opens Draw Things when a picture needs it** (`DrawThings.openIfNeeded`, called by
  the job runner around step 1, so the app and `mimic` both do it). Only when its API isn't
  answering and it isn't running at all: one that's open with its API server off isn't Mimic's
  to open or quit, and the request says how to turn the server on. Opened hidden without taking
  focus; the wait ends when the API answers, the app exits, or after 90 s (an app that opens and
  never answers almost always has its API server off, and says so). Only the instance Mimic
  opened is ever quit (`terminate`, never forced): after the picture, unless the queue's next
  job needs it too, and when the runner lets go of the queue. Liveness is by pid, since
  `NSRunningApplication.isTerminated` is updated on a main run loop `mimic` doesn't run; the
  launcher was tried live from a command-line process with its main thread blocked (Chess:
  opened in 0.25 s, not frontmost, quit when asked). Settings → Open Draw Things when needed
  (`openDrawThings`, on by default); with it on, Draw Things being closed is green in Settings
  ("opens when needed") and New Mini's grey sculpt and Describe it only need it installed with
  FLUX.2 Klein. Tests use a fake launcher (`FakeApp`): never the real app.
- **The first-run tour is popovers on the real controls** (`Sources/Mimic/TourGuide.swift`;
  when it starts and what comes next is `MimicCore/Tour.swift`, tested). Anchor preferences
  can't reach the toolbar or the New Mini sheet, which are hosted apart from the window's
  content; a popover can, and never covers what it points at. `interactiveDismissDisabled`
  keeps one up while you click around (without it a click anywhere ended the tour); Skip and
  Esc end it, and a stop whose control isn't on screen (no mini yet) is skipped. The sample
  picture ships in SwiftPM's `Mimic_Mimic.bundle`, which `bundle.sh` copies into
  Contents/Resources; it's looked up by hand, not through `Bundle.module`, whose accessor
  stops the app when the bundle is missing. Seen once: Help → Show Tour replays it.
- **The AI helper for descriptions is optional and off by default** (`MimicCore/Helper.swift`).
  Claude, any OpenAI-compatible service (key + address + model, only `model` and `messages`
  sent, since some models refuse `max_tokens` or `temperature`), or Ollama on this Mac. Claude
  defaults to Haiku 4.5: the rewrite is short and the person waits for it in the sheet, and it
  costs half of Sonnet 5.5. Keys are generic passwords in the login Keychain (service
  `com.mimic.app`, one account per provider), never in UserDefaults, settings.json or a log;
  error text a service sends back has the key cut out. Only the description is sent. The
  improved text is saved as `desc` (what was drawn) and what the person typed as
  `descOriginal`, so Try Again redraws exactly and never asks the helper again. Its answer goes
  into `characterPrompt` after "miniature of a", so the prompt asks for a noun phrase and a
  leading article or a repeated "miniature of a" (gemma3 did) is cut off. Ollama gets
  `think: false`: without it gemma4 and glm-4.7-flash reasoned past the 120 s limit. Measured on
  this Mac, once loaded: gemma3:4b 7–12 s per description, gemma4 8–15 s, glm-4.7-flash 8–10 s
  (and once described a dwarf when asked for an elf archer); a first call that loads the model
  took up to about a minute, so the limit is 300 s. Cloud providers are proven against a local
  fake server only. Key reads happen off the main thread: an ad-hoc-signed update is a new
  identity to the Keychain, so macOS may ask once to let Mimic use the saved key.
- **One job at a time, and a queue shared by every Mimic** (`MimicCore/Queue.swift`, `Jobs.swift`;
  0.5.0). A job asked for while one runs, in this Mimic or another (the installed app, a dev
  build, `mimic` in Terminal), joins `runs/.queue.json`: an array of `{name, job, added, sizes?}`,
  oldest first, only ever replaced whole. Everything is checked when it's asked for, and a new
  mini's folder, settings.json and picture are written then, so a queued job can't fail for a
  reason knowable at that moment; a resize keeps its sizes in the entry until it starts, so the
  mini keeps its size meanwhile. Every change to the queue happens under `runs/.queue.lock`
  (flock, a fresh open per section, since flock doesn't keep apart two threads sharing one open
  file), and so does every taking and letting go of `runs/.job.lock`. That one rule is what keeps
  a job from being lost: a runner that finds nothing waiting releases the job lock *inside* the
  queue lock, so a job added a moment later always finds the lock free and starts itself; a
  runner that finishes a job with more waiting starts the next without letting go. Whoever holds
  the job lock runs the queue: the app always carries on; `mimic make` carries on only until its
  own mini is made, then leaves the rest; quitting the app stops carrying on (the queue waits
  for the next launch, which starts it without asking). A crash lets go of the job lock outside
  that rule, so the app looks every 3 seconds and at launch. `runs/.job.json` names the running
  job and its holder's pid and start time, so another Mimic can show it (a record left by a
  crash reads as nothing). Proven with two `JobRunner`s on one folder, which is exactly two
  processes as far as flock is concerned: 16 jobs from two threads never overlap (a step that
  fails if another is inside it) and none is lost; 300 additions from two threads all land.
  Dropping the queue's flock fails both. Two things this fixed on the way: a job's leftover is
  now stopped only by a Mimic that got the job lock (before, opening a second Mimic stopped a
  live job it took for a crash's leftover), and the lock files are opened close-on-exec (a job's
  programs inherited them, so after a crash a program still running would have held the lock).
- **Learned time estimates** (`MimicCore/Timings.swift`). Every job a Mimic finishes on this Mac
  is a line of `~/Library/Application Support/Mimic/timings.jsonl`: date, Mimic version, the Mac
  (chip, memory, GPU cores), make or resize, character or object, model, where the picture came
  from, sizes, each step's seconds, and finished, failed or stopped. Capped at 2,000 lines; kept
  on this Mac only, never uploaded, and not in the minis folder, so sharing that shares none of
  it. A development Mimic (`MIMIC_HOME`, `MIMIC_FAKE_HOME`) keeps its own; `MIMIC_TIMINGS` names
  a file. Each step is estimated on its own, as the median of the 15 most recent similar jobs
  that finished on this Mac (same chip and memory): the picture from jobs whose picture came the
  same way (Draw Things takes a minute, a copy takes nothing); the 3D shape from makes with the
  same model; the print file from makes and resizes alike at the same nozzle and a height within
  30%, else any. Fewer than 3 and it's the fixed figure (the model's whole-mini minutes from the
  table above, less a minute for the picture and 45 s for print prep). Failed and stopped jobs
  never count. "Taking longer than usual" is 1.35× the estimate and "unusually slow" 2.8×, the
  old 12 and 25 minutes against 9 as proportions, with a minute's slack so a short job isn't
  called slow. Not measured: whether height and nozzle move print prep enough to matter here
  (every mini on the Mac this was built on is 32 mm), so the size match is a guess that costs
  nothing when it's wrong. The first run seeds the history from minis already made, only where
  their files' times can be trusted: the job log's birth is the start, pixal3d.log's birth the
  3D step's, the log's last change (the `[3/3]` line) print prep's, the print file's time the
  end; skipped unless the log is exactly the three step lines, pixal3d.log is newer than the log
  (Try Again appends to an old one), no resize came after, and the whole took 1 minute to 3
  hours. On this Mac that took 2 of the 4 finished minis (6:19 and 9:04 for Pixal3D).
- **Self-signed, by decision.** The disk image is downloaded through a browser, so macOS
  quarantines it and the first open needs System Settings → Privacy & Security → Open Anyway,
  once; the README and a note in the disk image say so. A Developer ID would remove that step.
- **Updates: our own updater, not Sparkle** (`MimicCore/Updates.swift`, `Mimic/UpdateView.swift`;
  0.5.0). Sparkle would be Mimic's first third-party code, and would need its own framework and
  XPC services copied into the hand-assembled bundle by `bundle.sh`, an EdDSA key pair, and an
  appcast feed generated and published by the release workflow. Its EdDSA signature is the one
  thing it adds over what's here: it protects against someone who takes over the GitHub
  account and publishes a release, but only if the private key lives somewhere other than CI,
  which for a one-person hobby project it would not. Ours is a few hundred lines on what releases already
  have: `releases/latest` (GitHub documents that it leaves pre-releases and drafts out; not
  observable here, since the engine's pre-release predates 0.4.1; and `Updates.offer`
  also refuses them and any tag that isn't `vX.Y.Z`, so the engine's `pixal3d-d1b4926`
  pre-release is never an update), the disk image and its line in the release's `SHA256SUMS`.
  That checksum comes from the same release over TLS: it catches a damaged or cut-off download,
  not a compromised account. The download reuses setup's `fetch` (resumes, deletes a file whose
  sha256 is wrong). Then `hdiutil attach -nobrowse -readonly -noautoopen` at a mount point of
  its own (an open disk image would push it to "Mimic 1"), `ditto` Mimic.app to a hidden
  `.Mimic-update-<uuid>.app` beside the running app (same disk, so the swap is a rename), check
  it (version equals the release's, bundle id `com.mimic.app` so settings carry over,
  `codesign --verify --deep --strict`), and `renamex_np(RENAME_SWAP)`: one step, never a moment
  without a Mimic there. The old app then sits at the hidden name and is removed; a launch
  sweeps any left over. Relaunch is a small `sh` that waits for this pid to end, then
  `open -n` the app with Mimic's own `MIMIC_*` variables, so a test copy stays a test copy.
  The shell means the old and new Mimic never run at once. A window with a sheet (or an alert,
  which SwiftUI shows as one) up refuses to quit, so those are closed first (seen: with the
  update sheet up, the old Mimic stayed open).
  Checked at launch and then from the queue's 3-second watch, at most once a day counted from
  the last *attempt* (an offline Mac doesn't retry every 3 seconds); "Last checked" is the last
  success. A development build (`AppVersion` parses only `X.Y.Z`) never checks by itself and a
  manual check says so. Never while a mini is being made (here or in another Mimic), waiting in
  the queue, or the engine downloading: Update becomes "Update When the Queue Is Done", and the
  rule is checked again after the download and after staging. Where the account can't write
  the app's folder (another user's /Applications, a translocated copy, the disk image itself)
  it downloads the disk image, checks it and opens it instead. Sent: a GET with User-Agent
  `Mimic/<version>`, nothing else. Quarantine: URLSession sets none (Mimic's Info.plist has no
  `LSFileQuarantineEnabled`), so the new app opens without Open Anyway; checked on the real
  update below (`xattr`: no `com.apple.quarantine` anywhere in it; `com.apple.provenance` is
  not quarantine). The Keychain (#13): an ad-hoc signature's identity is the binary's hash,
  so after any update macOS may ask once to let Mimic use a saved AI key (see the AI helper
  above); not seen, since the test copy had no saved keys. Seen end to end with a throwaway
  "Mimic Update Test" (own bundle id, version 0.4.1, a debug build, in a scratch folder,
  `MIMIC_FAKE_HOME` set): `MIMIC_UPDATE_NOW=1` (debug builds only) checked and pressed Update,
  it downloaded the real 0.4.2 disk image, verified it, replaced itself with the real Mimic
  0.4.2 (Info.plist 0.4.2, `com.mimic.app`, signature valid), quit, and the new one started
  with the same `MIMIC_FAKE_HOME`, about 8 seconds in all.

## Not yet seen working

- Dragging a mini onto a project in the sidebar, and the right-click menus on a mini and a
  project's header: seen in the test build were the sections (Unsorted last, an empty project's
  "Drag minis here"), the Mini menu's Move to Project ▸ moving a mini, and New Mini's Project
  picker starting on the selected mini's project. The background automation's synthetic drags
  never started a drag session, and it can't open context menus.

- Setup's full download (8.1–9.1 GB) through the app, and closing the window mid-download: the
  download path is proven by tests against a local server and by a real run of the engine and
  the small files; the window close is `applicationShouldTerminateAfterLastWindowClosed`, and
  before it closing the setup window quit Mimic (seen).

- A notification arriving: the permission prompt is asked once after the first Make (seen:
  status went from "not asked" to "denied" on the dev app), but none has been seen delivered.

- The queue's Dock badge and the quit question's queue sentence: both are one line each, but
  the test build ran in the background, where neither the Dock tile nor the modal alert could
  be seen.

- Whether macOS's App Management protection steps in for an ad-hoc app in /Applications: if
  it does, removing the old app fails quietly and a hidden `.Mimic-update-*.app` is left beside
  the new one.

- Updating from /Applications and ~/Applications, and the not-writable path (a standard
  account with Mimic installed by an administrator: disk image opened instead): the swap and
  the refusal are tested on temporary folders, and the real update ran in a scratch folder.
  The update sheet, toolbar note and Settings section were not looked at: the test drove the
  update through `MIMIC_UPDATE_NOW`, not the buttons.
