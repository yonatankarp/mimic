# Parity with the web version

Everything the web page (`ui/`) and its server do today. The web version is removed only when
every box is ticked, in the app (and the command line where marked).

## Making a mini
- [ ] Picture: drop, click to choose, paste (⌘V); preview shown
- [ ] Warning before making when the picture is small (< 512 px) or wider than tall
- [ ] "Turn it into a grey sculpt first" (FLUX.2 Klein edit), on by default
- [ ] Describe it: text, name filled from the first words (skipping a/an/the), another-version button
- [ ] Name, shown as "Dwarf Cleric", stored as `dwarf-cleric`; a taken name is refused
- [ ] Size for: Game scale (real height × 28/32/54 mm) and Best print (64/100/150 mm by nozzle)
- [ ] Game scale warns when the nozzle is too coarse for the size
- [ ] Nozzle 0.2 / 0.4 / 0.6, remembered; sets the extra thickness
- [ ] Character height and base size: slider plus typed value, clamped
- [ ] Advanced: extra thickness, keep the character's own base, variation number
- [ ] Make is blocked, with the reason, when a required check fails
- [x] Command line: `mimic make <name> "<description>" | --image <file> [--restyle] [--height …]`, plus `mimic resize` and `mimic retry`; Ctrl-C stops the job

## While it's being made
- [x] One job at a time
- [ ] Progress window: three steps, bar, elapsed time, the 7–10 minute note
- [ ] "Taking longer than usual" after 12 minutes, "unusually slow" after 25
- [ ] Run in Background / minimize, with progress still visible (Dock, and wherever the pill went)
- [ ] Stop, with a confirmation; ends every program the job started
- [ ] A stopped new mini goes to the Trash; a stopped resize keeps the old size
- [ ] Finished: Open in <slicer>; failed: Try Again (same inputs), and Open Setup when Draw Things was the cause
- [ ] A notification when it's done (asked once)
- [ ] Quitting during a job asks first; a job left from a crash is stopped on the next launch

## The mini
- [ ] 3D view: drag to turn, zoom locked by default with a toggle, Front resets, double-click resets
- [ ] Size shown ("34 mm tall · 25 × 33 mm")
- [ ] Previews: your picture, front, side, back; click to enlarge
- [ ] "Now: 32 mm character · 25 mm base · made for a 0.2 mm nozzle" and its sizes loaded into the size card
- [ ] Resize this mini (print prep only, ~30 s)
- [ ] Print tips for the nozzle, and Copy settings
- [ ] Open in <slicer>, Show in Finder
- [ ] A "fragile thin parts" warning when print prep reports one

## Gallery
- [x] Newest first, dated by the print file, "_" folders hidden
- [x] Search past six minis
- [x] Context menu: Open in <slicer>, Show in Finder, Rename…, Move to Trash…
- [x] Rename renames the folder and every file named after it; keeps the date
- [x] Move to Trash, with a confirmation

## Settings
- [ ] Nine health checks, run one at a time with a spinner each, required vs optional, "last checked"
- [ ] Blender and the 3D engine are actually started, never assumed
- [ ] A warning on the Settings entry point when a required check fails
- [ ] Draw Things setup steps while it isn't ready, watched continuously
- [ ] Slicer: the detected ones, or the Mac's default app for STL files
- [ ] Open the minis folder

## Tests ported from Python
- [x] `test_cancel.py` → `GroupProcessTests`
- [x] `test_settings.py` (made only on success; Try Again rebuilds the same command)
- [x] `test_rename.py`
- [ ] `test_checks.py` (every check red and green, with injectable paths and Draw Things address)
- [x] `test_serve.py` input checks (names, numbers, nozzle)
- [ ] `test_prep.sh` stays (it tests the Blender script, not the app)
