<p align="center"><img src="docs/images/logo.png" width="160" alt="Mimic's logo: a cartoon treasure-chest monster with a tiny grey miniature standing in its open mouth"></p>

<h1 align="center">Mimic</h1>

<p align="center"><b>Turn any character into a miniature you can print.</b><br>
Drop in a picture, or describe your character, and Mimic makes a 3D-printable mini of it.<br>
Everything runs on your own Mac: no accounts, no uploads, no subscriptions.</p>

![A picture of a dwarf cleric, and the printable mini Mimic made from it, seen from the front and side](docs/images/pipeline.jpg)

## 🚀 Get started

### What you need

- A Mac with Apple silicon (M1 or newer), on macOS 26 (Tahoe) or newer. Every such Mac can
  update to it for free, in System Settings → General → Software Update.
- 32 GB of memory
- About 25 GB of free space
- A 3D printer, and a slicer for it, such as [Bambu Studio](https://github.com/bambulab/BambuStudio),
  [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer), [PrusaSlicer](https://github.com/prusa3d/PrusaSlicer)
  or [UltiMaker Cura](https://github.com/Ultimaker/Cura)
- Optional: [Draw Things](https://apps.apple.com/app/id6444050820), a free app. With it, Mimic
  can make a mini from a description, and turn your picture into a grey sculpt first, which
  gives better minis. Mimic shows you how to set it up. Mimic connects to it through
  Draw Things' command line tool, which it downloads with its 3D engine, so Draw Things doesn't
  need to be open.

### Install

1. Download the `.dmg` file from the [latest release](https://github.com/yonatankarp/mimic/releases/latest) and open it.
2. Drag **Mimic** onto **Applications**, then open Mimic from your Applications folder.
   If your Mac says it can't check Mimic, see the note below.
3. Pick a 3D model (TRELLIS.2, the default, keeps what a figure holds most reliably; Pixal3D
   is faster, with the crispest surface) and press **Download**. The first time, Mimic
   downloads its 3D engine (8.3 to 9.3 GB, depending on the model). You can keep using your Mac while it does, and
   switch models later in Settings → 3D Model.

> [!IMPORTANT]
> **The first time you open Mimic, your Mac may say it can't check it.** Mimic is a free app
> that isn't registered with Apple, so it needs one extra step:
> 1. Press **Done** on that message.
> 2. Open **System Settings → Privacy & Security**.
> 3. Scroll down to *"Mimic was blocked"* and press **Open Anyway**.
> 4. Confirm with your Mac password or Touch ID.
>
> You only do this once.

## 🧙 Making a mini

![Mimic: your minis on the left; a finished halfling bard in a 3D view in the middle; its size, filament, previews and how it was made in a panel on the right](docs/images/app.jpg)

1. Press **New Mini** (⌘N), and choose what you're making: 🧙 **A character** (a tabletop mini) or
   🏺 **Anything else** (a teapot, a car, a chess piece).
2. Drop in a picture of it, or switch to **Description** and write a sentence.
3. Pick your printer's nozzle and how big to make it.
4. Press **Make Mini**. A mini takes about 8–15 minutes, depending on the 3D model, and New
   Mini shows how long on your Mac. Keep using Mimic meanwhile: its progress is in the toolbar
   (click it for the steps, the queue and Stop), and Mimic tells you when it's ready. Closing the
   window doesn't stop it: it carries on in the Dock, which counts the minis ready to see.
5. Press **Open in …** to open it in your slicer, or drag one of its previews to Finder or any
   slicer, and print. Each mini's page shows the slicer settings to use.

> [!TIP]
> Mimic explains each choice as you make it. If something isn't set up, **Needs Setup** appears
> in the toolbar: it opens **Settings** (Mimic → Settings, ⌘,), which tells you what's missing and how to fix it.

Your minis are saved in **Documents → Mimic**.

Projects, versions, sizes and bases, magnets, exporting for virtual tabletops, importing
models, every setting and shortcut: the **[Mimic guide](https://yonatankarp.github.io/mimic/)**
explains it all.

---

## 🛠️ More

- **[Mimic from a terminal](https://yonatankarp.github.io/mimic/cli/):** Mimic is also a `mimic`
  command, with JSON for scripts and completion as you type.
- **[How it works](https://yonatankarp.github.io/mimic/how-it-works/):** from a picture to a
  print-ready STL, all on your Mac.
- **[Working on Mimic](https://yonatankarp.github.io/mimic/developing/):** building, testing and
  releasing. To send a change, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Licences

<!-- --8<-- [start:licences] -->

- **Mimic:** MIT (see [LICENSE](https://github.com/yonatankarp/mimic/blob/main/LICENSE)). The app carries this licence and Sparkle's in
  `Mimic.app/Contents/Resources/Acknowledgements.txt`.
- **Sparkle:** MIT, with the notices of the code it includes. It's built into the app, for updates.
- **pixal3d.cpp and ggml:** MIT. The 3D engine, built from them; Mimic hosts the build that
  setup downloads, with both licences in it.
- **draw-things-cli:** GPL-3.0. Setup downloads it from Draw Things' own releases, and Mimic runs
  it as a separate program.
- **TRELLIS.2 and Pixal3D:** MIT, except the image encoder their models include, which uses
  Meta's DINOv3 licence.
- **FLUX.2 Klein:** Black Forest Labs' licence. Check it before selling prints of generated
  characters.
<!-- --8<-- [end:licences] -->
