# Changelog

What's new in each version of Mimic. The release workflow publishes a version's section here as
its release notes, so write it for people who use Mimic, not for developers.

## 0.2.0

Mimic is now a real Mac app. Download the disk image, drag Mimic to Applications, and open it.

### New
- **A Mac app instead of a web page.** Your minis on the left, a 3D view you can turn, previews
  from every side, and print tips for your nozzle on each mini's page.
- **Sets itself up.** The first time you open it, Mimic downloads its 3D engine (8.1 GB) with
  progress shown. No Terminal, no installer script. If you used an earlier Mimic, it reuses
  what you already downloaded.
- **Much faster print files.** Making the print-ready file takes seconds instead of a minute
  (a 32 mm mini: about 6 s instead of 58 s), uses a quarter of the memory, and keeps finer
  detail in faces and beards.
- **Better cut-outs.** Your Mac cuts your character out of its picture itself, keeping thin
  parts like bow tips and hammer heads that used to get lost.
- **Nothing else to install.** Blender, Python and Homebrew are no longer needed.
- **New macOS look**, with animations while you wait, tooltips on every choice, and a Mini menu
  with keyboard shortcuts (⌘O open in slicer, ⌘R resize, ⌘⌫ move to Trash).
- **Settings** (⌘,) checks everything Mimic needs and shows how to fix anything missing.
- **`mimic` in Terminal**: make, resize and retry minis from the command line. Settings shows how
  to set it up.

### Good to know
- The first time you open Mimic, your Mac asks you to allow it once: see
  "If Mimic won't open.txt" in the disk image.
- Needs a Mac with Apple silicon, macOS 15 or newer, and 32 GB of memory.
