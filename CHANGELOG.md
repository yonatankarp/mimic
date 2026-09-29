# Changelog

What's new in each version of Mimic. The release workflow publishes a version's section here as its release notes, so write it for people who use Mimic, not for developers.

## 0.3.0

Mimic now shows you around, and makes more than characters.

### New
- **A quick tour** the first time you open Mimic. It points at the real buttons, and offers to make your first mini from a sample dwarf picture so you learn by doing. Replay it any time from Help → Show Tour.
- **Make anything, not just characters.** New Mini starts with "What are you making?": a character (a mini, as before) or anything else, like a teapot, a vehicle or a statue. Objects get drawn and sculpted as objects, are sized by their longest side, are straightened to stand level on their own bottom, and get no round base unless you want one.
- **Report a problem or share an idea** from the project page: the forms ask for exactly what helps.

### Good to know
- Your existing minis stay characters. Resize and Try Again keep whatever a mini was made as.
- In Terminal: `mimic make teapot "a round teapot" --object`.

## 0.2.0

Mimic is now a real Mac app. Download the disk image, drag Mimic to Applications, and open it.

### New
- **A Mac app instead of a web page.** Your minis on the left, a 3D view you can turn, previews from every side, and print tips for your nozzle on each mini's page.
- **Sets itself up.** The first time you open it, Mimic downloads its 3D engine (8.1 GB) with progress shown. No Terminal, no installer script. If you used an earlier Mimic, it reuses what you already downloaded.
- **Much faster print files.** Making the print-ready file takes seconds instead of a minute (a 32 mm mini: about 6 s instead of 58 s), uses a quarter of the memory, and keeps finer detail in faces and beards.
- **Better cut-outs.** Your Mac cuts your character out of its picture itself, keeping thin parts like bow tips and hammer heads that used to get lost.
- **Nothing else to install.** Blender, Python and Homebrew are no longer needed.
- **New macOS look**, with animations while you wait, tooltips on every choice, and a Mini menu with keyboard shortcuts (⌘O open in slicer, ⌘R resize, ⌘⌫ move to Trash).
- **Settings** (⌘,) checks everything Mimic needs and shows how to fix anything missing.
- **`mimic` in Terminal**: make, resize and retry minis from the command line. Settings shows how to set it up.

### Good to know
- The first time you open Mimic, your Mac asks you to allow it once: see "If Mimic won't open.txt" in the disk image.
- Needs a Mac with Apple silicon, macOS 15 or newer, and 32 GB of memory.
