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
  Mimic → Install Command-Line Tool… shows the one command that links the app's binary onto
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
    prep prints `mini_prep: WARNING part: <what to tell the person>` in prep.log and puts the
    same words in its report to the job (prep-result.json), which the mini's page, the
    progress window and `mimic make` show as it is. Measured on the seven minis in the
    gallery at their own sizes: the Pixal3D elf's bow was 30 mm long (93% of 32 mm) and
    54 mm³; the largest solid speck on any of them was 0.93 mm (0.93% of 100 mm) and 0.001
    mm³. The 10% leaves an order of magnitude either side. `testRealMinisWarnOnlyOfARealPart`
    reruns that on a folder of model.glb files (`MIMIC_PREP_MINIS`). The part is left out
    rather than kept as a second body in the STL: slicers print several bodies, but this one
    floats where the hands held it, so it prints as a loose piece needing supports and glue,
    not as held. Make Another Version or TRELLIS.2 (which joined the bow on every seed, #2)
    is the fix, so that's what the warning says.
  - **A base in the picture is left out** (`Mesh.baseTop`). A picture of a character on a base
    (even after the grey sculpt, whose prompt says "no base") comes back with the engine's copy
    of it: a hollow drum, open underneath, usually wider than Mimic's base. Stood on Mimic's
    base it hung over the edge on supports, its rim ragged where `--flatten` cut it, and the
    figure was sized from the drum's bottom, so it came out 5–8% short. Its top is the tell: a
    wide flat face low down. Measured on 13 real models (both engines), counting faces within
    0.95 of level either way up (the engine's surfaces are two-sided and its winding isn't
    reliable), in hundredths of the height squared, within half a hundredth of each height up
    to 12%: the three with a base in the picture peaked at 5,317 (TRELLIS.2 brute, base top at
    7.7%), 3,219 (Pixal3D dwarf, a base in two steps, top at 5.4%) and 1,899 (TRELLIS.2 fairy,
    her robe over most of it, 4.7%); the ten without at most 751 (Pixal3D Lorelei's robe, 375
    counting up only), then 315 and under. `Prep.baseFlat` is 1,200, about 1.6 times from
    each. Shifting the bins by half a width found the same three and none of the ten. A peak
    also needs a fifth as much flat or less in the hundredth above it, so a robe of many small
    flats doesn't count, and the highest that qualifies is the top of a base in steps. The
    figure is sized from that top and set on Mimic's base from it, sunk a further inflate and
    two voxels so the drum's top skin goes with it, and the field cuts the figure (not the base)
    0.6 mm into Mimic's base (`Solid.figureFloor`). The footprint is measured from 1% above the
    top, or the drum's top counted. Not in Export for Virtual Tabletop's placement of a print
    file made before placement records, which must place it as it was made. `--no-base` keeps
    the drum as the character's own; objects are never looked at. A miss leaves the drum as
    before; a false hit would cut the bottom of the feet off, and needs a flat area the size of
    a disc about 40% of the height across.
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
  folders and files at the top are never either, so a folder from
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
- **Edit & Make Again** (#84) opens New Mini filled in from a mini (`MakeForm.again`, next to
  Make Another Version and from the same saved source): picture or description (the one typed,
  with the helper's version shown), the grey sculpt, cartoon, sizes and base, project, variation
  number (kept, so an unchanged description draws the same, with New 3D Shape's `shapeSeed`
  until the number is changed) and the next version's name. Not
  `versionOf`: once edited it's a mini of its own. New Mini has no model control, so the model it
  was made with is carried only while it's downloaded, and the sheet says so with a way back to
  the Mac's choice. The tour's sample fills New Mini the same way. A test makes a mini again
  from the form unchanged and compares every setting, so one the form drops fails it.
- **New 3D Shape** (#86) is Make Another Version that keeps the picture: `make` copies the old
  mini's source.png into the new folder before it joins the queue, so the plan skips step 1 as
  it does for Try Again, and a new `shapeSeed` in settings.json goes to `_engine --seed` alone
  (absent, `seed` drives both). `seed` stays, so the base stones and a redrawn picture come out
  the same. Offered only when source.png is there.
- **Duplicate** (#85, `MimicCore/Duplicate.swift`) keeps a second mini of the same shape to
  resize, since Resize replaces the only print file and Make Another Version changes the shape.
  The copy is made in a `_duplicate-…` folder next to it (never listed, so never taken over as a
  Finder copy half made), its files renamed after it and its settings given the new name, then
  moved into place, all under the queue's lock; a mini being made, resized or waiting can't be
  duplicated. Everything comes along but the logs (they tell how the original was made, and
  would count it twice in the estimates) and a half-written print file. It isn't one of the
  original's versions (Keep This One would trash it) and is asked for now. The name offered is
  the next number, as for versions ("Raven 2"), not a size: the size is chosen after, in Resize.
- **Import Model** (#96, `MimicCore/Import.swift`): a GLB or STL made elsewhere becomes a mini
  that only print prep runs on. The file is read and checked before anything is written; the
  new folder gets settings.json (`imported`, the file's name, a field of its own: a new
  `source` value would make an older Mimic read the whole file as empty) and `model.glb`, then
  a print prep job joins the queue. With model.glb there, the gallery, Resize and Duplicate
  treat it as any mini, and no 3D engine is needed. A GLB is y up by its spec; an STL is taken
  as z up, as slicers take it. Both are written again as a GLB with their triangles joined
  where their corners meet (to a millionth of its size): an STL keeps no corner shared and many
  GLBs split them at seams, and print prep finds a model's main pieces (`Mesh.mainBounds`, what
  an object is sized by, and `Mesh.rest`'s hull) by shared corners. There's no cheap,
  reliable way to tell an STL's up from its shape, so a wrong one shows in Previews and the 3D
  view (an object may still be stood on a steadier side by `Mesh.rest`). An STL is taken as
  millimetres; one under 5 mm or over 500 mm on its longest side gets a line in prep.log saying
  which unit it was probably in, though sizing rescales it anyway. It's never turned (`--turn`
  is for what TRELLIS.2 made). With no picture or description, Try Again, Make Another Version,
  New 3D Shape and Edit & Make Again are off and say why; Resize makes its print file again.
  Until its first print file is made, its print prep is "Importing", not "Resizing", and taking
  it out of the queue or stopping it sends it to the Trash, as for a new mini.
- **A mini has two names** (#87; all in `Rules.swift`, "Names people type"): the one typed,
  kept in settings.json as `name` ("Élodie", "D&D Bard", "McGregor") and shown everywhere
  (list, page, notifications, Open Together's objects, `mimic list`'s last column), and its
  folder's, which its files, the queue and every `mimic` command go by. The folder's is
  `Rules.folderName`: other alphabets and accents in plain letters (ICU's Any-Latin, then
  strip diacritics, then Latin-ASCII for ß and æ), then the old slug, and "mini" when nothing
  is left (only emoji), so Make is never blocked by a name. Collisions are as before: Make and
  Rename refuse a folder name that's taken; pictures dropped together and new versions take
  the next number, and so does their shown name ("Élodie 2"). Older minis have no `name` and
  show their folder's as before. **When the folder and settings.json disagree, the folder
  wins**, since renaming or copying it in Finder is what the person did last: the name is
  kept with `nameFolder`, the folder it was given for, and shown only while the folder still
  has that name. So a copy ("raven copy", taken over as `raven-copy`) never passes for the
  original, a folder renamed in Finder shows its new name, and that holds for an unfinished
  mini the takeover never touches. A folder renamed in Finder to a name with capitals or
  accents ("Élodie la Druide") is taken over with that name kept as typed. A rename in Mimic
  without a typed name (the kept version taking the plain name, and its Undo) carries the old
  name along while it still fits the new folder (`Rules.shownName(carrying:to:)`).
- **A picture is tidied once, when it's added** (`Engine.tidied`, called by `make` before
  anything is written): turned upright, no longer than 2048 on its longest side, and written as
  PNG to `upload.img` (the name is from when it was a plain copy; kept so older minis read the
  same). The cutout and its edge cleaning ran on every pixel of a 48 MP photo for an engine that
  sees 1536 at most. New Mini takes drops as a picture file, else as the picture's data or a
  promised file (Photos, browsers), never a web address; Import from iPhone goes the same way.
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
  box 4 or 6 times as tall as wide stands (14°, 9.5°), 8 times (7.1°) can't stand. Standing on
  a side within 10° of down, it is left alone however much steadier lying would be: a vase, a
  pillar or a statue with a flat back is never laid down, so "much more stable elsewhere" is
  deliberately not a reason. Otherwise it goes onto the steadiest side (most lift,
  sqrt(r² + h²) − h, to tip it; nearest to down on a tie) within 30° of down, and never further.
  Laying down whatever couldn't stand turned out wrong on real models: a hoodie guy (centre of
  mass outside his feet) and a perched raven came out upright from the engine and were laid on
  their backs. With no side near its bottom to stand on, it is left as the engine made it, the
  levelling undone too (it had tipped the raven 27° onto its tail and perch), and without a base
  the person is told it needs one. So an object that really came out on its side or upside down
  now stays that way; only turned test models ever did. It runs after levelling and nothing levels after it: the side's facing is already exact. The
  real teapot had been levelled 2.8° onto the edge of its foot and printed 20° askew; it now
  stands on its foot. teapot2, the vase and every character give the same bytes as before;
  turned 90° either way or 180° they used to come back upright on their bases, which is what
  was given up above. 0.3–0.5 s for a million triangles in a release build. Characters never go through this.
- **Same data on disk.** `runs/<name>/` (or `runs/<project>/<name>/`) with `<name>.stl`,
  `<name>_{front,left,right,back}.png`, `source.png` and `settings.json` (`requested` / `made`
  / how it was made), so minis made by the web version appear in the app unchanged. An older
  mini's `_side.png` goes when its previews are next drawn (`Render`). The list is in the order
  minis were asked for, `created` in settings.json (#75; older minis go by their folder's
  creation date), not by the print file's time, which every resize changes; the 3D view, the
  thumbnails and `mimic --wait` still watch that time to notice a new print file. The gallery
  reads each settings.json once per reload into `Mini.settings`, which the list, a mini's page
  and the estimates use, so a redraw or a progress tick reads no file (#95). A `Mini` compares
  its settings too, so a reload after a run or a rename shows what changed; jobs, Try Again and
  the command line still read the file, since they must see what's on disk now.
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
  core idle in front, 0% behind. In a sheet (Compare Side by Side) the Metal layer's
  `contentsScale` comes out 0, which draws every frame at no size, so each draw sets it to the
  window's. It has no default ambient light, so it carries its own grey
  studio light, matched to the old look by brightness.
- **A size reference in the 3D view** (#98, `MimicCore/SizeReference.swift`, tested). Every
  mini is shown 1 tall, so a millimetre is 1 / its height: a 25 mm base ring, a 32 mm person
  or a millimetre grid on the floor, drawn at that scale, one choice for the whole app
  (`sizeReference`). The print file's origin is under its base's middle (print prep puts it
  there), so the ring and the grid are centred on it, not on the box, which a raised sword
  stretches; a file whose origin is outside its footprint is centred on the box. It is a child
  of the mini's entity, so it turns, zooms and glides with it; the person is two crossed
  cut-outs so it doesn't vanish edge-on, and stands clear of the mini's box. The ring is a band
  outside 25 mm, so a 25 mm base doesn't hide it. Grid squares grow to 2, 5 or 10 mm when a
  millimetre would be under 2.5% of the mini's height (over 40 mm), with bold lines every
  centimetre; the badge says the square's size. The camera fits the mini and the reference
  together, as far below the middle as above so the mini stays put, which means a person beside
  something 10 mm tall makes it small: that's the point.
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
  handled before the CLI finds the Mimic folder: the queue's `job.pid` names this very
  program, and the leftover-job cleanup would otherwise stop it.
- **Why a step failed comes from its report, never its log** (#305). `_engine` writes what it
  says for people (no character found in the picture, the engine missing or ignoring
  PIXAL3D_STEPS: press Repair) into the same prep-result.json print prep reports through, and the
  job reads it the same way; paths and exit codes go to pixal3d.log only (`Engine.Failure.forPeople`).
  A program killed outright (signal 9: macOS ends the biggest one that way when memory runs out)
  can't write one, so trellis-cli's -9 is said by `_engine`, and a step's own -9 by the job
  (`JobStep.outOfMemory`). With no reason at all the job says which step stopped, in that step's
  own capitals ("3D"). Proven by `testTheEngineReportsWhyItFailed` and
  `testTheReasonThe3DStepFailedIsSaid`.
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
  `model` default (absent = Pixal3D in 0.4.0, so installs from before kept working with nothing to
  download; TRELLIS.2 since 0.6.0, below), and each mini records its model in settings.json so Try Again uses it. Only sets
  proven end to end with this engine build are offered. Measured on the dwarf (seed 42, M2 Max
  32 GB, `mimic make … --model <id>` through the app's own `_engine` and `_prep`):

  | Model | Download | Flows (sum) | Whole mini | Max RSS of any step |
  |---|---|---|---|---|
  | Pixal3D (`pixal3d-sv`, the 0.4.0 default) | 8.1 GB | 5.5 min | 7.5 min | 5.1 GB |
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
  figure facing the other way from Pixal3D's. Print files face -y, a slicer's front (#275), as
  TRELLIS.2 writes it, so print prep turns Pixal3D's round instead (`--turn 180`, `EngineModel.turn`).
  Before 0.10.0 they faced +y, and those files stay as they are: the 3D view and Export for
  Virtual Tabletop turn them round (`Mini.facesAway`). A finished run records `facesFront`; a print
  file without it is old if it's older than 0.10.0's release, unless it was imported (never turned).
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
- **Cartoons: the grey sculpt, then Pixal3D** (0.7.0, [#3](https://github.com/yonatankarp/mimic/issues/3);
  New Mini's "It's a cartoon", `EngineDownload.forMaking`). A flat 2D cartoon given straight to
  TRELLIS.2 came out as a flat sheet, 0.1 mm thick. With the grey sculpt both models give a
  recognisable figure, but TRELLIS.2 builds it out of flat panels (head, limbs), already in the
  engine's own output, and smoothing afterwards didn't fix it. Pixal3D's is smooth. Seen on
  Piposh (three pictures from a game's model sheet, not committed: someone else's character) and
  on the two pictures in `docs/cartoon-check/`, drawn for this with Draw Things: a chubby frog
  knight (big head, stubby limbs) and a 1930s-style wizard with noodle-thin legs and a thin staff.
  Both came out smooth and in one piece at 34 mm, with no fragile warning, and the sculpt kept
  the cartoon proportions. So the sculpt prompt has nothing cartoon-specific yet.
  **The cartoon check:** when the sculpt prompt, the Draw Things model or a 3D model changes,
  make both pictures as cartoons and compare them with the minis above. From the repository:
  `MIMIC_HOME=. "app/build/Mimic Dev.app/Contents/MacOS/mimic" make cartoon-frog --image
  docs/cartoon-check/frog-knight.png --restyle --model pixal3d-sv` (and `noodle-wizard.png`).
  Look for panels, lost limbs or staff, and the frog's face. `testTheSculptPromptsAreChecked`
  fails whenever the prompt text changes, to remind whoever changed it.
- **Model files come straight from Hugging Face,** pinned to a revision, each file checked
  against its sha256; the app's check compares every file's size.
- **Pictures of the back and sides** (0.9.0, [#66](https://github.com/yonatankarp/mimic/issues/66);
  `PictureSide`). New Mini takes optional Back, Left and Right pictures besides the front one;
  each goes through the same step 1 (copied, or redrawn as a grey sculpt) so all of them look
  alike to the engine, and the 3D step hands them to TRELLIS.2's multi-image mode
  (`--trellis2-mv DIR`, 2–8 pictures, read in file-name order, "pose-free fusion": no cameras,
  so the labels only order them). Mimic cuts each out and puts them in `model.mvviews/` as
  `1-front.png`, `2-back.png`, … (front first). Kept as `upload-<side>.img` and
  `source-<side>.png` beside upload.img and source.png, listed in settings.json's `sides`
  (absent: one picture, so older minis read unchanged); step 1 skips each picture already made
  on its own. Checked by hand on this engine build (M2 Max, 2026-10-01): the elf's front, side
  and back renders gave a whole figure in 615 s against about 222 for one picture, every flow
  printing `[flow-mv] 12 steps`: the multi-image flows ignore `PIXAL3D_STEPS` and show no
  progress bar, so the steps guard never fires and the estimate counts the 3D step 2.8 times
  as long (`Estimator.multiViewShape`). The figure faces the same way as from one picture, so it
  needs no turn either. The sculpt prompt names no view, and a sculpt of the back
  render stayed a back view (its shoes came out pointing at the camera, the one slip), so side
  pictures share the front's prompt. Step 1 is one run per picture but timed as one step, so
  its time left doesn't start over for each. Pixal3D's single-view set takes one picture, so New Mini shows
  the slots only when the model it will use can take them (#254; a cartoon is always Pixal3D).
  Pictures already added stay while they're hidden, and `sidesUsed` sends none of them. Pixal3D's four-picture
  multiview set is still not offered. Left out for now: Draw Things drawing the missing views
  from the front, and lining the pictures up (same height, feet on one line) before the engine.
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
- **The queue is per Mac, and the minis folder can be changed** (#102, `Install.queue`,
  `MinisFolder.swift`). The queue's files (`queue.json`, `queue.lock`, `paused`, `job.lock`,
  `job.json`, `job.pid`) were at the top of the minis folder; with Desktop & Documents in iCloud
  two Macs would share one queue file while each locks only for itself. They're in
  `~/Library/Application Support/Mimic/queues/<key>`, the key the first 16 hex digits of the
  SHA-256 of the minis folder's path. One queue per minis folder, not one per Mac or per app:
  the dev app (its own settings, so its own folder choice) and the installed app share a queue
  exactly when they share a folder, so two never run jobs in one folder at once and a queued
  name never resolves in the wrong folder. The path is hashed as given, with links unresolved,
  since a folder that doesn't exist yet resolves differently once it does; the app and `mimic`
  read the same settings, so they agree. A Mimic folder (`MIMIC_HOME`, tests) keeps its queue in
  `queue/` inside it (git-ignored), and `MIMIC_FAKE_HOME` inside the fake home. No
  compatibility with 0.8.0 or an old `mimic` sharing the queue, since nobody else used it yet.
  0.9.0 moved the queue files 0.8.0 kept in the minis folder at every launch; 0.10.0 dropped
  that move (#222), so a queue left by 0.8.0 is no longer picked up. Settings → General → Change… picks another folder (`minisFolder`
  in the app's settings, kept by Reset like `installDir`, and ignored under `MIMIC_HOME` and
  `MIMIC_FAKE_HOME`, where the button is off). The minis either move there or stay put (for a
  folder that already has minis). Refused while a mini is being made or waits, in any Mimic using
  the folder, and for a folder inside the current one or holding it (one would become a project
  of the other). A move takes every mini and project, a project whole with any files of the
  person's own, and a project whose name is taken there (without case) merges into that one.
  A mini or project whose name is taken there stops the whole move, naming each: renaming on the
  way would leave a folder disagreeing with its settings. A failed move puts back what moved,
  and the setting is saved only after it worked. While the files move the queue is marked
  `moving` (the mover's pid and start time, so a crash leaves no mark) but its lock isn't held:
  held, a Make (the app's or `mimic make`) waited on it for the whole move and then wrote its
  mini into the folder just emptied. Marked, Make, Resize, Try Again, Duplicate, moving a mini
  and the project changes are refused with "Mimic is moving your minis", and the mark comes
  off only after the setting is saved, so asking again finds the new folder. The app then makes a new job runner for the new
  folder; the gallery and the folder watch follow on the next reload.
- **First launch sets itself up** (`EngineDownload.swift`, ported from `setup.sh`): the pinned
  engine tarball and Hugging Face files, each with its size and sha256 in one manifest that the
  health check also reads. Downloads go to `<name>.part` and resume with HTTP Range (checked
  against a local server that logs the Range asked for and the bytes served: a re-download
  would end with the same sha256); a finished file with the wrong sha256 is deleted so Try
  Again starts it afresh; files already right are hashed and kept. It runs in the app, so
  closing the window doesn't stop it (the app stays open while it runs). Until 0.10.0 it also
  moved the engine out of an install from before 0.2.0 (`image-to-3dlab/vendor/pixal3d-cpp`);
  that move is gone (#222), and such an install downloads the engine again. Settings offers Download / Repair on the two engine checks;
  the engine check also wants the pinned `VERSION`, so a new engine pin shows up as Repair.
  `MIMIC_FAKE_HOME` (a new Mac's home folder, `installDir` ignored) and `MIMIC_DOWNLOAD_MIRROR`
  (a local server instead of the internet) are for trying it.
- **Notifications work from the self-assembled app:** `mimic --probe-notifications` inside
  the bundle read the settings without a prompt (status 0, not yet asked). The probe has since
  been removed.
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
  ("opens when needed") and New Mini's grey sculpt and Description only need it installed with
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
  costs half of Sonnet 5.5. Keys are generic passwords in the login Keychain (service the
  bundle id, one account per provider), never in UserDefaults, settings.json or a log. The
  service was the fixed `com.mimic.app` until #313, so Mimic Dev's Reset deleted the installed
  app's keys; now Mimic Dev has `com.mimic.app.dev` (keys saved by older dev builds aren't read:
  save them again), Mimic is unchanged, and a binary outside an app (`mimic` through a symlink,
  `swift run`) reads Mimic's keys, as it reads Mimic's settings, but its Reset deletes none;
  error text a service sends back has the key cut out. A redirect is followed without the key's
  header unless it's to the scheme, host and port the key was saved for (`sendsKey(to:)`, through
  the online pictures' `KeepKey`; #376): in testing URLSession dropped `Authorization` on a
  redirect by itself, even to the same address, but carried Anthropic's `x-api-key` anywhere. Only the
  description is sent. The improved text is saved as `desc` (what was drawn) and what the person
  typed as
  `descOriginal`, so Try Again redraws exactly and never asks the helper again. Its answer goes
  into `characterPrompt` after "miniature of a", so the prompt asks for a noun phrase and a
  leading article or a repeated "miniature of a" (gemma3 did) is cut off. Ollama gets
  `think: false`: without it gemma4 and glm-4.7-flash reasoned past the 120 s limit. Measured on
  this Mac, once loaded: gemma3:4b 7–12 s per description, gemma4 8–15 s, glm-4.7-flash 8–10 s
  (and once described a dwarf when asked for an elf archer); a first call that loads the model
  took up to about a minute, so the limit is 300 s. Cloud providers are proven against a local
  fake server only. Key reads happen off the main thread: an ad-hoc-signed update is a new
  identity to the Keychain, so macOS may ask once to let Mimic use the saved key.
- **Pictures can be made online instead of by Draw Things** (#247, `MimicCore/OnlineImages.swift`).
  Settings → Pictures (`imageService`: `drawthings`, the default, `bfl` or `openai`). Each online
  service is one `OnlineService` entry, in its own file (`BlackForestLabs.swift`,
  `OpenAIImages.swift`): the name people see, its Keychain account, its "Get a key" page, its
  address, the header its key goes in, the hosts the key may go to, the free GET that checks the
  key, and its client. Settings, the checks, the report, New Mini, Fixes and every error read the
  name from the entry, so no other file names a service (a test checks each one's messages name it
  and no other). `OnlineClient` is what the clients share: the key (read only as a request goes
  out), Stop, and `fetch`, which sends the key only to the address it was set up with (scheme, host
  and port) or the entry's hosts over https, follows a redirect anywhere else without the key's
  header (`KeepKey`), and cuts the key out of error text before it's shortened. Errors are
  `OnlineImagesError(problem, service: name)`, in the same plain words for every service.
  `PictureMaker` is the one seam: `DrawThings` and each online client are one, and the job runner
  picks one as each job starts (`JobRunner.pictureService`), so Stop cancels the one in use, and a
  change in Settings counts from the next job. The entry's free check is Settings' Test and the
  `images-online` check, which replaces the three Draw Things checks; it isn't in the Draw Things
  watch, which would ask every few seconds. The errors never say "Draw Things", or the popover
  would send people to its setup steps. No `--image-service` flag: a per-make choice would have to
  be saved with the mini, since the app may run it from the queue later. What comes back is scaled
  to the size asked for if it isn't it, so the 3D step gets what Draw Things would give.
  - *Black Forest Labs* runs the same FLUX.2 Klein, so the prompts in `DrawThings.swift` carry
    over word for word. The model is pinned to `flux-2-klein-9b`, which both draws and edits.
    `input_image` is a PNG data URL (`data:image/png;base64,…`) at `DrawThings.editSize`: the
    OpenAPI only says "Path to the input image", and BFL's own FLUX.2 example
    (cookbook/video_start_from_images) sends a local file that way; Kontext's page also takes bare
    base64. PNG is asked for (the default is JPEG). The API is async: submit, then ask the
    `polling_url` every 0.5 s for up to 300 s (a 5xx, 429, timeout or dropped connection meanwhile
    is asked again, since the picture is paid for; "Task not found", a 404, is final), then fetch
    `result.sample`, which needs no key and gets none (#309). The fetch has to be a 200: a 429, a
    5xx, a timeout or a dropped connection goes back to asking, until the same deadline, so the next
    try uses the address the next Ready gives. Anything else (an expired signed address is 403 or
    404) asks once more, in case BFL signs a fresh address; whether it does isn't known, so the same
    address failing again ends the job saying the download link stopped working, rather than
    waiting out the 300 s. The fetch doesn't go through the JSON reply's statuses, where 403 means
    a wrong key. Seen live with made-up keys: none or an
    unknown one is 403 "Not authenticated", one not shaped like a key is 422 "Invalid API key
    format"; both read as a wrong key. The key is `x-key`, to https `*.bfl.ai` (polling addresses
    can be regional), Keychain account `bfl`, checked by `GET /v1/credits`. There's no cancel in
    the API, so a stopped request is probably still charged.
  - *OpenAI* is pinned to `gpt-image-2.5-sunburst`: OpenAI's docs recommend it for generating and
    editing (Flare is the faster everyday one), and a grey sculpt has to keep the character. Text
    to picture is `POST /v1/images/generations` (JSON), picture to picture `POST /v1/images/edits`
    as multipart with the picture as `image[]`, a PNG at `DrawThings.editSize`. Both ask for
    `output_format: png` and `background: opaque` (a see-through background would leave the 3D
    step nothing to cut out), and the picture comes back in the reply as `b64_json`. The size asked
    for is the one wanted when the model takes it (sides in multiples of 16, at most 3:1, 655,360
    to 8,294,400 pixels), else the same shape with a 1536 long side and the short side in
    sixteens, at least 512: past 3:1 that's 1536x512, the nearest it takes, since the scaling
    stretches. One synchronous request, so Stop cancels it (whether OpenAI still
    charges a cancelled one isn't known); its timeout is 300 s, as OpenAI says a picture can take
    two minutes. No seed: the Image API has none, so Try Again and a variation number don't
    reproduce a picture. Quality is left at `auto`, OpenAI's default. The prompts are FLUX's,
    unchanged: GPT Image models read whole sentences, and these already say each thing the 3D step
    needs (one full-body figure, a plain light grey background, an unpainted grey sculpt, no base)
    in plain words; without a real-key run there's nothing to tune them against, so any OpenAI
    wording would go in `OpenAIImages.swift` once one shows a need. Seen live with made-up keys:
    none, a malformed one and an unknown one are all 401 `invalid_api_key`, whose message repeats
    part of the key, so it's never shown; only that code is a wrong key. Any other 401 (a
    restricted key without a scope, an address not on the project's list) is shown in OpenAI's
    words, and the free check passes a 401 whose message says "Missing scopes": a restricted key
    allowed to make pictures but not to list models is still a key OpenAI knows, and failing it
    would turn off descriptions and the sculpt for a key that can make them (the message shape is
    from OpenAI's restricted-key answers, not seen live). A 429 is out of credits when its type is
    `insufficient_quota` or its code is a billing one from OpenAI's error codes guide
    (`credit_balance_exhausted`, the organisation and project spend limits, the organisation usage
    limit): asking again won't help, so the message says to add credits or raise the limit. Any
    other 429 or a 5xx is busy, 400 `moderation_blocked` a refusal with its `moderation_details`
    categories; anything else, such as 403 for an organisation not yet verified for GPT Image, in
    OpenAI's own words. The key is `Authorization: Bearer`, to https `api.openai.com` only,
    Keychain account `openai-images` (the helper's OpenAI key is `openai`; one key for both would
    mean removing it in one place removes it from the other), checked by `GET /v1/models`.
    URLSession drops `Authorization` on a redirect to another host by itself, so `KeepKey` is
    tested directly for it.
  Both are proven against local fake servers only.
- **Report a Problem makes a zip and opens a filled-in issue** (`MimicCore/Report.swift`, `Log.swift`;
  #100). A link can't attach a file, so Help → Report a Problem… (or the action on a mini that
  didn't finish) writes `runs/_reports/mimic-report-….zip`, shows it in Finder, and opens
  bug.yml's form with `version`, `mac`, `logs` (drag it in) and, for a mini, `what` filled in
  through the form's field ids. The zip always has the build line, the Mac (`hw.model`, the chip,
  memory, macOS), the app's own log and, for a mini, every `*.log` in its folder (the last 2 MB of
  each) and settings.json; the picture only when the alert's "Include the picture (the issue is
  public)" is ticked, off by default. Renders and the 3D files never. Every text file is scrubbed
  before it's zipped: API key and token patterns (`sk-ant-`, `sk-`, `hf_`, `gsk_`, GitHub, Slack,
  AWS, `Bearer …`, `api_key=…`-style values) and the home folder as `~`, also as JSON writes it
  (`\/Users\/…`). The saved helper key itself isn't read to scrub by: no job log contains it (it's
  only ever sent in a request header), and reading it may show a Keychain prompt. Reports go in
  the minis folder because Mimic can already write there; Downloads or the Desktop would ask for
  permission first. The app's own log is `Logger` (subsystem the bundle id; categories setup,
  download, queue, shown) at notice and up with `.public` values, since a default-private value
  reads back as `<private>`. `OSLogStore(scope: .currentProcessIdentifier)` reads it with no
  permission (checked on this Mac, and by a test); the whole Mac's store needs an administrator.
  So a report has this launch's last hour only, never an earlier launch or `mimic` in Terminal.
  The setup (`ReportSetup.swift`, #283) goes in as setup.txt and, its first nine lines cut to
  100 characters each, into the form's `more`: the 3D model and engine VERSION, Draw Things' model
  (asked of its API only; reading its models folder would show a privacy prompt) and cli or app,
  the helper's provider (never its key or address), free space, `kern.memorystatus_vm_pressure_level`,
  power, the Metal GPU, the queue and last job by kind and step (never a name), and the nozzle,
  base and grey sculpt of the mini, else the last job's, else New Mini's. Priority is fixed (nice
  10), so it's stated, not read. A picture of the main window and its sheets (not Settings) goes in
  as window.png when "Include a picture of Mimic's window" is ticked, on by default under a preview:
  taken as the action starts, before the alert, by drawing the views (`cacheDisplay`), which needs
  no Screen Recording permission. What Metal draws, the 3D view, may come out empty.
- **A crash is offered as a report at the next launch** (`MimicCore/CrashReport.swift`; #284). The
  app and `mimic` are one binary, so both crash as `mimic-….ips` in `~/Library/Logs/DiagnosticReports`
  (an .ips is a header line of JSON, then the report's JSON). At launch the newest one written since
  `crashSeen` is offered once, whatever the answer; with no `crashSeen` (first launch, or after Reset)
  only one from the last day is, so old crashes aren't dug up. Hang reports have no crashing thread
  and are skipped. Report adds `crash.json` to Report a Problem's zip: the exception, termination
  and `asi` (the fatal error's message), the crashing thread's frames with their library's name
  inlined, and only those libraries; never the other threads, register state, or the report's
  user, device, boot and incident ids. The issue's title is the exception and the top frame in
  Mimic's own binary (the trap and `abort` frames above it say nothing), with the crashed version.
  The crashed launch's log comes from `log show` filtered by its pid, which works on an
  administrator account only; on a standard one about.txt says it couldn't be read. It's run by
  `Checks.execute` with a 60 s timeout (about 1 s is usual), so a stuck `log` can't hang the report. Crashes of
  trellis-cli and draw-things-cli aren't offered: they're failed jobs, with Report a Problem on
  the mini. Don't Ask Again is `crashDontAsk`. The setup (#283) goes in too, as it is at the
  next launch: the crashed launch's queue and last job went with it.
- **One job at a time, and a queue shared by every Mimic** (`MimicCore/Queue.swift`, `Jobs.swift`;
  0.5.0). A job asked for while one runs, in this Mimic or another (the installed app, a dev
  build, `mimic` in Terminal), joins the queue's `queue.json` (on this Mac, see #102 below): an array of `{name, job, added, sizes?}`,
  oldest first, only ever replaced whole. Everything is checked when it's asked for, and a new
  mini's folder, settings.json and picture are written then, so a queued job can't fail for a
  reason knowable at that moment; a resize keeps its sizes in the entry until it starts, so the
  mini keeps its size meanwhile. Every change to the queue happens under `queue.lock`
  (flock, a fresh open per section, since flock doesn't keep apart two threads sharing one open
  file), and so does every taking and letting go of `job.lock`. That one rule is what keeps
  a job from being lost: a runner that finds nothing waiting releases the job lock *inside* the
  queue lock, so a job added a moment later always finds the lock free and starts itself; a
  runner that finishes a job with more waiting starts the next without letting go. Whoever holds
  the job lock runs the queue: the app always carries on; `mimic make` carries on only until its
  own mini is made, then leaves the rest; quitting the app stops carrying on (the queue waits
  for the next launch, which starts it without asking). A job stopped by quitting goes back to
  the front of the queue while its runner still holds the job lock, instead of to the Trash
  (#82): the step it was on loses its half-written file (the picture), and the plan skips
  every step whose file is there, so it carries on from the last step it finished. trellis-cli
  writes its model in place, so it builds it in `model.building/` beside model.glb and `mimic
  _engine` moves it up only once it exits 0 with the file written (#316): model.glb is there
  only when it's whole, even after a crash or a leftover stopped at launch, which skip that
  clean-up. Each run empties `model.building/` first, and removes it when it ends. A log-out, restart or shutdown (the
  quit event's reason) doesn't ask first: the question would hold the Mac up, and quitting
  loses nothing but the step in progress. A crash lets go of the job lock outside
  that rule, so the app looks every 3 seconds and at launch. `job.json` names the running
  job and its holder's pid and start time, so another Mimic can show it (a record left by a
  crash reads as nothing). Proven with two `JobRunner`s on one folder, which is exactly two
  processes as far as flock is concerned: 16 jobs from two threads never overlap (a step that
  fails if another is inside it) and none is lost; 300 additions from two threads all land.
  Dropping the queue's flock fails both. Two things this fixed on the way: a job's leftover is
  now stopped only by a Mimic that got the job lock (before, opening a second Mimic stopped a
  live job it took for a crash's leftover), and the lock files are opened close-on-exec (a job's
  programs inherited them, so after a crash a program still running would have held the lock).
  A `queue.json` that won't read under the lock (#306) is damage, never a write in progress (every
  write replaces it whole, under the lock), so a change renames it to
  `queue.json.unreadable-<date>` and starts from an empty queue; if it can't be renamed the change
  is refused. Before, it read as empty and the next change saved that over every job waiting. A
  new `JobKind` is how a newer Mimic breaks it for an older one (Codable skips unknown fields, not
  unknown cases). The app says so once when a new copy appears, from any Mimic.
- **Pausing the queue, and battery** (#89). Paused is the queue's `paused` file, a file of its own
  so every Mimic and `mimic queue pause|resume` share it; a field in `queue.json` would have
  broken 0.7.0, which reads that file as a bare list (it would see an empty queue and drop the
  pause on its next write). 0.7.0 ignores the pause. It is checked, under the queue's lock,
  wherever a job could start (taking the job lock, and the next job after one ends), so
  pausing lets the running one finish: Pause After This One. Settings → Start minis only when
  plugged in (`Power`, IOKit's providing power source; shown only on a Mac with a battery) holds
  the queue the same way, in the app and in Terminal, since both read the app's settings; the
  app's 3-second watch starts it again once the Mac is plugged in. `mimic queue resume` only
  lifts the pause and leaves starting to the app: the command ends at once, and a job needs
  its runner to stay. An update still waits for a held queue to empty, as for any waiting job.
  Job programs run under `/usr/bin/nice -n 10`, which execs them in place (same pid, same
  group, so Stop and the leftover record are unchanged) and is inherited by what they start.
  Measured on an idle M2 Pro, CPU work on every core took as long at nice 10 as at 0 (2.1 s
  and 2.2 s). Not measured: a whole mini, whose long step is the 3D engine on the GPU.
- **`mimic stop`** (#129) is a different program from the Mimic making the mini, so it can only
  ask: it writes the running job's name to the queue's `job.stop`, and the runner holding the job lock
  (the app, or `mimic make` in another Terminal) looks for that file twice a second and stops its
  job as its own Stop does (a new mini to the Trash, a resize keeps its size). Killing the pid in
  `job.pid` instead would have been recorded as a failure, not a stop. A request naming another
  job is dropped, and one nobody answers within 10 seconds (a Mimic from before 0.9.0) is taken
  back, so it can't stop a later job of the same name.
- **Reordering the queue** (#72): Move to Front, Up, Down, to End or to a place
  (`JobRunner.move`, `mimic queue move`), and dragging one waiting mini onto another's place in
  the progress popover. Every move is one read-change-write under the queue's lock, so two
  Mimics can't fight over the order or lose a mini added meanwhile. Only waiting minis move,
  one at a time (minis added together don't move as a group), and Move to Front never stops the
  one being made: stopping stays its own action, so the front is simply the next to start.
- **Learned time estimates** (`MimicCore/Timings.swift`). Every job a Mimic finishes on this Mac
  is a line of `~/Library/Application Support/Mimic/timings.jsonl`: date, Mimic version, the Mac
  (chip, memory, GPU cores), make or resize, character or object, model, where the picture came
  from and which service drew it (`pictureService`, 0.12.0), sizes, each step's seconds, and
  finished, failed or stopped. Capped at 2,000 lines; kept
  on this Mac only, never uploaded, and not in the minis folder, so sharing that shares none of
  it. A development Mimic (`MIMIC_HOME`, `MIMIC_FAKE_HOME`) keeps its own; `MIMIC_TIMINGS` names
  a file. Each step is estimated on its own, as the median of the 15 most recent similar jobs
  that finished on this Mac (same chip and memory): the picture from jobs whose picture came the
  same way (a copy takes nothing; a drawn one from the same service, #325: Draw Things about 20 s,
  OpenAI a minute or two); the 3D shape from makes with the same model; the print file from makes and resizes alike at the same nozzle and a height within
  30%, else any. Fewer than 3 and it's the fixed figure (the model's whole-mini minutes from the
  table above, less a minute for the picture and 45 s for print prep). Failed and stopped jobs
  never count. A record without `pictureService` counts as Draw Things: it was the only way
  before 0.11.0, and 0.11's online pictures can't be told apart, so they count as Draw Things
  until newer drawn makes push them out of the 15. "Taking longer than usual" is 1.35× the estimate and "unusually slow" 2.8×, the
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
- **Updates: Sparkle** (`Mimic/UpdateView.swift`; issue #15). A first updater of our own
  (GitHub's `releases/latest`, the disk image checked against `SHA256SUMS`, swapped in place)
  was built for 0.6.0 and replaced by Sparkle before it shipped: the updater most Mac apps
  outside the App Store use, so the one everyone relies on from 0.6.0 is the proven one. Its
  EdDSA signature also covers what a checksum from the same release can't: a release published
  by someone else. Sparkle 2 comes through SwiftPM, linked into the `Mimic` target only (rpath
  `@executable_path/../Frameworks`, which dyld resolves through the real path, so `mimic`
  symlinked into `/usr/local/bin` still finds it). `bundle.sh` copies `Sparkle.framework` into
  `Contents/Frameworks` with `ditto` (it's full of symlinks) and drops its XPC services, which
  only sandboxed apps need; then it signs inside out, `Autoupdate`, `Updater.app`, the framework,
  the app, with the same identity and no `--deep`. Info.plist: `SUFeedURL`
  (`releases/latest/download/appcast.xml`, so always the newest release's), `SUPublicEDKey`, and
  `SUEnableAutomaticChecks` off: Sparkle's own schedule never runs, and the key being there at all
  stops Sparkle asking on the second launch whether to check. Sparkle compares `CFBundleVersion`, the commit count. The updater only starts in the
  release build (`com.mimic.app`): the dev build has no Check for Updates… and no Settings →
  Updates, and never updates itself.
  Checked when Mimic opens, not once a day (#269): 5 s after launch, so the window doesn't land on
  a mini being started, `checkForUpdatesInBackground` if Settings → Check for updates when Mimic
  opens is on (`UpdateCheck.key`, Mimic's own setting; until 0.10 the switch was Sparkle's
  `automaticallyChecksForUpdates`, carried over once and removed, since saved as on it overrides
  the Info.plist and brings the daily timer back, whose window would land mid-queue). A Mimic left
  open for days hears of a release when it's next opened, or from the menu: accepted. An update
  found shows Sparkle's window through `checkForUpdates()`, the same "show in focus" as the
  toolbar note, only while Mimic is the active app (that call activates it; otherwise it waits
  for `becameActive`, so Mimic never jumps in front of another app): told to show it itself, Sparkle holds a scheduled update back until the app is
  next activated once more than 3 s have passed since the updater started. Remind Me Later
  (`userDidMake` `.dismiss`) leaves the note in the toolbar until the next launch, which asks
  again; Skip This Version is Sparkle's (background checks never find a skipped version). With
  automatic checks off, Sparkle's window no longer offers "Automatically download and install
  updates" (it follows that setting), so every update goes through the window. Check for
  Updates… is Sparkle's standard UI. Seen with a test build on a local appcast: the window 6 s after launch;
  none for a skipped version, nothing new, offline or the switch off; the old switch's off carried
  over. Its buttons weren't clicked.
  Never installing while a mini is being made (here or in another Mimic), waiting in the queue,
  or setup downloading: `shouldPostponeRelaunchForUpdate` holds Sparkle's go-ahead, the note
  says "installs when the queue is done", and the queue's 3-second watch gives it back once the
  queue is empty, closing any sheet first (a window with a sheet up refuses to quit; seen with
  the first updater). An update installed on quit instead needs nothing: quitting already asks
  about a running mini, which goes back to the front of the queue, and the queue carries on at
  the next launch. Sparkle sends no system
  profile (`SUEnableSystemProfiling` is off by default).
  Releasing: the release job (macOS, for `hdiutil`) runs `generate_appcast` from the pinned
  Sparkle 2.10.0 tarball on the disk image, with the version's release notes (made from its pull
  requests by `tools/release_notes.py`) as Markdown notes, and publishes `appcast.xml` with the release. The private key lives in the
  maintainer's Keychain and in the `SPARKLE_PRIVATE_KEY` secret, passed on stdin; a key that
  doesn't match `SUPublicEDKey` fails the release rather than publishing an unsigned update.
  Checked locally with a throwaway key: the enclosure URL, `sparkle:version`, the Markdown notes
  and a signature that verifies. Not yet seen: a real update from one release to the next.
- **Colour from the 3D engine, through where print prep put its model (#256).** The tabletop
  export (#158) colours the trimmed print file, not the engine's own model: the print file has
  the base and the thickened parts a tabletop mini should have, and the engine's model can have
  holes. For each point of it, `EngineColours` undoes print prep's placement, finds where the
  line through it along the surface's normal meets the engine's model (a uniform grid, `Nearest`,
  walked cell by cell) and samples its base colour texture at that point's place on the picture.
  Projecting the picture from the front was tried first and
  looked bad from a tabletop's angles (streaks down the sides, the front seen through on the
  back), so colour has to come from the engine, which paints all round.
  - **Placement is recorded, not worked out again.** Print prep keeps one matrix next to the
    float work, step by step (the engine's turn, levelling and resting an object, the scale, the
    shift, then the --flatten `run` takes off after the solid), and writes it to placement.json
    beside the print file, in the z-up frame `GLB.read` (and Blender) gives the model. Working it
    out again from settings at export time would follow settings changed since the print file
    was made, and the first version of the export left out the --flatten, putting its colours
    0.4 mm high. Minis prepped before the record are still placed again, as print prep places
    them now: about a second.
  - **A baked texture, not vertex colours.** 5,000 triangles have about 2,500 corners, so vertex
    colours (`COLOR_0`) would give a face a handful of colours; a 2048-pixel texture gives each
    triangle a cell about 28 pixels wide (1.6 MB against under 100 KB grey; a tabletop loads it
    once). Each triangle has a cell of its own, so a texture's smoothing never reaches a
    neighbour's colours. Which tabletops draw it as intended hasn't been checked (Phroller's
    demo, Foundry, Owlbear Rodeo, TaleSpire).
  - **Along the normal, not the nearest point.** Print prep pushes the surface out by --inflate
    (0.16 mm on a 0.4 nozzle), so beside a strand of hair or a cord lying on the skin the nearest
    point on the model is the strand's edge: nearest point widened every one by the push on each
    side. Lorelei's face came out as dark smears with no eyes, and neither 50,000 triangles nor
    a 4096-pixel texture helped; weighting the trim toward the head or toward colour changes
    didn't either. Along the normal, the face reads at 5,000 triangles, the file grows by about
    0.1 MB and the bake is about three times quicker (fewer grid cells to search). The meeting
    nearest the surface either way along the line is taken, not the first from outside: the same
    on her face, cleaner where her hand touches her cheek, and the normal's direction doesn't
    matter. The line reaches as far as the nearest point would (3% of the height) but no more
    than 2 mm: 1 mm already found the model everywhere on a 28 mm Lorelei but her base and a few
    wing edges, and further on a big mini it could find a neighbouring part. Where it meets
    nothing (wing edges seen edge on, the base), the nearest point's colour is taken.
  - A point further from the model than 3% of its height takes the base's grey: that's the base.
  - The same lookups are what the colour print file (#41) and "Keep the picture's colours" (#256's
    step 4) can call.
- **A deep trim for the tabletop goes through a coarse grid first.** Print prep's grid is 0.1 mm
  whatever the size, so a 100 mm mini's print file keeps hundreds of tunnels too small to see
  (Lorelei at 100 mm: 358, against 83 at 28 mm). The trim never closes one, since it refuses
  collapses that change the shape's topology, and each keeps a ring of triangles. Trimmed 160 to 1,
  it stalled over 5,000 and its rising threshold took the base's rim and the wings instead (5,854
  triangles). The cause wasn't Decimate's thresholds being in millimetres: the same print file
  scaled down to 28 mm broke the same way. So when the print file has more than 60 triangles for
  each one kept, the export draws it again through `Solid` on a grid sized for 60 to 1, half a
  cell further out (a quarter of a millimetre at 100 mm), which closes the tunnels a few thousand
  triangles couldn't show anyway. Without the half-cell offset, the coarse grid punches new holes
  through thin wings. A milder trim is left as it was: it doesn't stall.

## Not yet seen working

- Import Model in the app (File → Import Model…, its sheet, and an imported mini's page and
  menus): the import itself, an STL through real print prep, and its refusals are tested; the
  windows weren't looked at, and no real HeroForge STL or other generator's GLB was tried.

- Report a Problem in the app: the alert, its picture boxes and the window's preview, Finder
  showing the zip, and the filled-in GitHub form. The zip, the scrubbing, the link and reading the app's log back are tested.

- The crash question at launch after a real crash of Mimic, and the crashed launch's log in its
  report: finding, trimming and scrubbing a made-up report, the zip and the link are tested, and
  `log show` by pid was tried on another process.

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
