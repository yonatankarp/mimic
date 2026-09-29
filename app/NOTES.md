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

## Not yet seen working

- Setup's full 8.1 GB download through the app, and closing the window mid-download: the
  download path is proven by tests against a local server and by a real run of the engine and
  the small files; the window close is `applicationShouldTerminateAfterLastWindowClosed`, and
  before it closing the setup window quit Mimic (seen).

- A notification arriving: the permission prompt is asked once after the first Make (seen:
  status went from "not asked" to "denied" on the dev app), but none has been seen delivered.

- The queue's Dock badge and the quit question's queue sentence: both are one line each, but
  the test build ran in the background, where neither the Dock tile nor the modal alert could
  be seen.
