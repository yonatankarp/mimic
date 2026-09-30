# Changelog

What's new in each version of Mimic. The release workflow publishes a version's section here as its release notes, so write it for people who use Mimic, not for developers.

## 0.7.0

### Changed
- **Mimic now needs macOS 26 (Tahoe).** Every Mac that runs Mimic can update to it for free, in System Settings → General → Software Update.

## 0.6.0

### New
- **Drag a mini out.** Drag any preview on a finished mini's page onto Finder, the Desktop, a slicer or a chat app to get its print file there, with the mini's name.
- **Drop several pictures on New Mini** and each becomes a mini in the queue, named after its file and made with the same settings. Rename them afterwards if you like.
- `mimic --version` (also `-v` and `mimic version`) says which Mimic you have, and `mimic --help` lists it.
- **Mimic checks for updates.** Once a day, and from Mimic → Check for Updates…: a new version shows as a small note in the toolbar; click it to see what's new and install it. Mimic checks that the download really comes from Mimic's makers, replaces itself and opens again, never while a mini is being made or waiting. Turn it off in Settings → Updates. Only public release information is read; nothing about your Mac or your minis is sent.
- **Draw Things without its API server.** Mimic downloads Draw Things' command line tool with its 3D engine (178 MB, once) and draws with it: Draw Things doesn't have to be open, and there's no API server to turn back on after it restarts. Pictures are always made on your Mac.
- **Pick the best version.** A mini's page shows its other versions side by side; click one to see it, and Keep This One moves the others to the Trash and can give it the plain name. Only versions made from now on are grouped.
- Your Mac no longer goes to sleep on its own while minis are being made or waiting, in the app or in Terminal. The screen can still turn off, and closing the lid still sleeps it.
- **Resize every mini in a project at once.** Right-click a project → Resize All…, choose one size, base and nozzle, and each mini waits its turn in the queue. Minis already that size are left out, and an object without a base stays without one.

### Changed
- **TRELLIS.2 is now the default 3D model.** It keeps what a figure holds — a weapon, a bow, a pet on a shoulder — far more reliably (9 of 9 in testing, against 4 of 10). Pixal3D stays in Settings → 3D model for the crispest surface. TRELLIS.2 Lite is gone. First launch now downloads about 9.3 GB.
- The tour no longer says a mini takes 7–10 minutes: it points to the time New Mini shows for your Mac. It also mentions the queue, dragging a mini out and projects.

### Fixed
- When several minis finish while you're away, each gets its own notification instead of replacing the last one.
- When something a figure holds (a bow, a staff) comes out of the 3D model separate from the figure, Mimic still leaves it out of the print file, but now says so on the mini's page, with how long it was and what to try, instead of dropping it silently.
- `mimic --help` prints the commands instead of opening the app.
- Mimic asks to show notifications the first time any mini starts, not only after Make, so a Resize or Try Again can tell you when it's done.

## 0.5.0

### New
- **A queue.** Press Make My Mini, Resize or Try Again while a mini is being made and it waits its turn instead of being refused: "Added to the queue — 1 ahead of it, ready in about 8 minutes".
- **See what's waiting** in the progress window and the toolbar: each mini with how long it takes and when it should be ready. Move one up, or take it out (a new mini's picture and settings go to the Trash).
- Minis waiting to be made show in your gallery as "Waiting (2nd)", with their picture. The Dock icon shows how many are waiting.
- **Stop ends only the mini being made**; the queue carries on with the next one. Quit and the queue waits: it starts again the next time you open Mimic, without asking.
- The queue is shared by every Mimic on your Mac, including `mimic` in Terminal: `mimic make` while Mimic is busy adds to the queue and tells you its place (`--wait` waits until it's made), `mimic queue` lists it, and `mimic queue remove <name>` takes one out.
- **Times that fit your Mac.** Mimic times every mini it makes and estimates the next from the ones like it: in New Mini ("about 8 minutes on this Mac"), in the progress window (time left for each step), for the queue, and for each 3D model in Settings. Until you've made a few, it uses its own figures.
- Settings → Time estimates says how many minis the estimates are based on, with Clear to start over. The times are kept on your Mac only and never sent anywhere.
- **Zoom with your mouse, where you point.** Scroll the wheel, or pinch or two-finger scroll on a trackpad, over the 3D view: it zooms toward the spot under the pointer, the same amount in as out. The "Pinch to Zoom" switch is gone; Face Front or a double-click puts it back.
- **Draw Things opens by itself.** When a mini needs a picture drawn, Mimic opens Draw Things in the background and quits it afterwards if it opened it, so you no longer have to open it first. Turn this off in Settings → Open Draw Things when needed.
- **Objects stand the right way up.** One that comes out on its side, upside down or tilted on the edge of its foot is set on its steadiest flat side before printing; one that already stands is left as it is.
- **Better AI descriptions.** Glowing, sparks and smoke are taken out of improved descriptions (they don't print), and Settings suggests the best local model you have installed.
- **Projects.** Group your minis into folders (the same folders in Finder): New Project at the bottom of the list (⇧⌘N), drag minis onto one or right-click → Move to Project, and rename or delete a project from its right-click menu. Deleting one asks whether to keep its minis (in Unsorted) or move them to the Trash too. New Mini asks which project it goes in; in Terminal, `mimic make … --project "Name"`, `mimic move`, `mimic projects`, and `mimic list` shows each project.
- **Make Another Version.** Right-click a mini (or the Mini menu) to make it again from the same picture or description and settings with a different variation number, next to it in the same project: a pet on a shoulder that came out as a blob may come out right. It waits its turn in the queue, so you can line up a few and keep the best. In Terminal: `mimic make-another <name>`.

### Fixed
- Mimic no longer asks again for your saved AI keys after an update: releases are now signed by the same signer every time.
- The 3D view no longer keeps your Mac busy while the mini just stands there: it used about a fifth of a processor core the whole time a mini was open, and now close to none.
- Opening a second Mimic (or running `mimic` in Terminal) while one was making a mini could stop that mini.

## 0.4.2

### New
- **Reset Mimic** (Settings, at the bottom): forget Mimic's settings and saved keys and see the tour again, as on a fresh install. You can also remove the 3D engine to go through first-launch setup again. Your minis are always kept.

### Fixed
- The tour no longer gets stuck at step 5. If you chose to make the sample dwarf, it waits for you to press Make My Mini; otherwise Next moves on.
- "Use the Sample" no longer gets cut off in the tour, and no empty panel is left on screen when the tour opens New Mini.

## 0.4.1

### New
- **See which Mimic you have.** The bottom of Settings shows the exact build (for example "Mimic 0.4.1 · build 106 · 04e41b1"), and so do Mimic → About Mimic and `mimic --version` in Terminal. Include it when you report a problem.

### Fixed
- **First launch could fail with "error 404"** while downloading the 3D engine, because the file's release page had been removed. It's back, and Mimic now checks every day that everything it downloads is still there.

## 0.4.0

Choose the 3D model Mimic uses, and let an AI helper flesh out your descriptions.

### New
- **Choose your 3D model.** Before the first download, and any time in Settings → 3D model. Each was timed making the same 32 mm dwarf on an M2 Max:
  - **Pixal3D** (the default, and what Mimic has always used): the sharpest faces and finest detail, and the fastest, about 8 minutes a mini. 8.1 GB.
  - **TRELLIS.2**: Microsoft's model that Pixal3D grew from. It can place things in depth better, like a hammer resting on a shoulder. About 14 minutes a mini. 9.1 GB.
  - **TRELLIS.2 Lite**: TRELLIS.2 made smaller, with nearly the same look and the smallest download. About 12 minutes a mini. 5.7 GB.
- **Switch, download or remove models in Settings.** Downloads pick up where they stopped, and Remove says how much space it frees first.
- **An optional AI helper for descriptions.** Type a short idea, press ✨ Improve Description, and get a fuller description to edit before Mimic draws it. Use Claude or any OpenAI-compatible service with your own key (kept in your Mac's Keychain), or Ollama running on your Mac. It's off until you choose one in Settings, and only the description is sent.

### Good to know
- Your existing install keeps Pixal3D and downloads nothing new.
- Each mini remembers its model, so Try Again uses the same one.
- Some files are shared between TRELLIS.2 and Pixal3D, so adding TRELLIS.2 (not Lite) next to Pixal3D downloads 2.2 GB less.
- In Terminal: `mimic models` lists them, `mimic make dwarf "a dwarf" --model trellis2-q4` uses one, and `--improve` asks the helper first.

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
