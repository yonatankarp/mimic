# Settings

Settings is where you check that Mimic has everything it needs, pick the 3D model it makes minis
with, set up Draw Things and the AI helper, and choose where your minis are kept. Open it from
**Mimic → Settings…** (++cmd+comma++). It has four tabs: **General**, **3D Model**,
**Draw Things & AI** and **Advanced**.

!!! tip
    You rarely need to go looking. If something stops Mimic making minis, **Needs Setup** appears
    in the toolbar, and clicking it opens Settings on the right tab.

## General

<!-- screenshot: settings-general.png | Settings, General tab, every check green ("Everything's ready."), Open Draw Things when needed on, Open minis in set to a slicer, the minis folder row and the Updates section at the bottom -->

### Check that everything is set up

The top of the tab lists what Mimic depends on, and checks each one every time you open Settings.
A green tick means it's ready. A red cross means Mimic can't make minis until it's fixed; an orange
triangle means only one feature is off. Under anything that isn't ready, Mimic says how to fix it.
Hold the pointer over a name to see what that part is for.

**Needed to make minis**

| Check | What it is | If it isn't ready |
|---|---|---|
| **3D engine** | Turns your picture into a 3D shape, on your Mac's graphics chip. | Press **Repair**: Mimic downloads it again. |
| **3D model files** | What the 3D engine has learned, for the 3D model in use. Downloaded once. | Press **Download**: Mimic fetches only what's missing. |
| **Free disk space** | Shows how much space is free. Each mini needs about 150 MB while it's being made. | Free up some space. The check passes with 5 GB free. |

**Optional**

| Check | What it is | If it isn't ready |
|---|---|---|
| **Draw Things app** | A free app that draws characters from a description and turns pictures into grey sculpts. | Install Draw Things from the Mac App Store. |
| **Draw Things is open and connected** | Lets Mimic ask Draw Things for pictures. It usually reads **Draw Things connected through its command line tool**, which means nothing more is needed. | See [Draw Things & AI](#draw-things-ai). |
| **FLUX.2 Klein model in Draw Things** | The picture model Mimic asks Draw Things to use. | In Draw Things' model list, search for FLUX.2 Klein and download it. |
| **A slicer to print with** | Turns a mini into instructions for your printer. | Install a slicer such as Bambu Studio, OrcaSlicer, PrusaSlicer or Cura. Mimic links to OrcaSlicer, a free one. |

Without the optional parts you can still make minis from your own pictures. Draw Things adds
making a mini from a description, the grey sculpt and **What to change**.

At the bottom of the list Mimic says how it went ("Everything's ready." or how many things to look
at) and when it last checked. **Check Again** runs the checks now. While a mini is being made the
checks wait, because they start the 3D engine the mini is using, and run when it's done.

### Open Draw Things when needed

On unless you turn it off. When a mini needs a picture drawn and Draw Things isn't running, Mimic
opens it in the background, and quits it afterwards if Mimic was the one that opened it.

Most of the time this doesn't come into play: Mimic draws pictures through Draw Things' command
line tool, which it downloads with its 3D engine, so Draw Things doesn't need to be open at all.
The setting matters only when that tool is missing.

If a Draw Things check fails, **Draw Things isn't set up yet** appears here with a
**Set Up Draw Things…** button, which takes you to the steps on the
[Draw Things & AI](#draw-things-ai) tab.

### Choose the slicer minis open in

**Open minis in** decides where **Open in …** sends a finished mini. Mimic lists the slicers it
finds in your Applications folder, such as Bambu Studio, OrcaSlicer, PrusaSlicer, UltiMaker Cura,
Creality Print, ElegooSlicer, Anycubic Slicer Next, SuperSlicer, ideaMaker, FlashPrint, Simplify3D,
Lychee Slicer and CHITUBOX. Until you choose, it uses the first one it finds.

Choose **Mac's default app for 3D files** to use any other slicer: Mimic then opens minis with
whichever app your Mac opens 3D files with.

### Wait for the charger on a MacBook

**Start minis only when plugged in** is off unless you turn it on, and only shows on a Mac with a
battery. When it's on and your Mac is running on its battery, the next mini waits in the queue.
One already being made carries on. Plug in and the queue starts again by itself. It holds minis
made in Terminal too.

### Choose where your minis are kept

**Your minis are saved in** shows the folder, which is **Documents → Mimic** unless you've changed
it. **Open Minis Folder** shows it in Finder.

To keep your minis somewhere else, press **Change…**, pick a folder and press **Use This Folder**.
Mimic then asks whether to move your minis there:

- **Move Minis** moves every mini and project to the new folder.
- **Don't Move** leaves them where they are. Mimic then shows only the minis in the new folder.
  Pick this when the folder already has minis of its own, say from another Mac: Mimic shows those.

You can change the folder once no mini is being made or waiting in the queue. Mimic won't use a
folder inside the one your minis are in now, or one that holds it, and it won't move minis onto
others with the same names: it names them, so you can rename yours first. If a move goes wrong,
your minis stay where they were. For more on the folder itself, see
[Where your files are](files.md).

### Updates

**Check for updates automatically** is on unless you turn it off. Mimic then asks GitHub for its
latest release once a day. Only public release information is read: nothing about your Mac or
your minis is sent. **Last checked** says when it last asked, and **Check Now** asks straight away.
You can also choose **Mimic → Check for Updates…** at any time.

When there's a new version, a note appears in the toolbar ("Mimic 0.10.0 is available", say).
Click it to see what's new and update. Mimic never installs an update while a mini is being made
or waiting: the note then says the new version installs when the queue is done, and it does.

## 3D Model

<!-- screenshot: settings-3d-model.png | Settings, 3D Model tab, TRELLIS.2 downloaded and In use, Pixal3D not downloaded with its Download button showing -->

Mimic can make minis with two 3D models. Each row shows its name, its size, what it's good at and
how long a mini takes. Once you've made a few minis, the time is the one measured on your Mac.

| Model | Size | A mini takes about | Good at |
|---|---|---|---|
| **TRELLIS.2** (the default) | 9.1 GB | 14 minutes | The most reliable with what a figure holds or carries: a weapon, a bow, a pet on a shoulder. A slightly softer surface, and slower on bulky figures. |
| **Pixal3D** | 8.1 GB | 8 minutes | The crispest surface detail, and the fastest. Sometimes loses or misplaces something a figure holds; **Make Another Version** usually fixes it. |

- **In use** marks the model new minis are made with.
- **Use** switches to a model that's already downloaded.
- **Download** fetches a model you don't have yet. Once it's done, Mimic uses it. A download that
  stopped shows **Resume Download**, which carries on where it left off. You can keep making
  minis meanwhile.
- **Remove…** deletes a model you aren't using and says how much space that frees. Minis you made
  with it stay, and you can download it again any time. You can't remove a model while a mini
  is being made.

!!! note
    Some things always use a particular model, whichever is in use:

    - A cartoon (**It's a cartoon** in New Mini) is always made with Pixal3D, so that needs
      Pixal3D downloaded.
    - **Try Again** uses the model the mini was first made with, so that model has to be
      downloaded.
    - Pictures of the back and sides only work with TRELLIS.2.

    The two models share some files, so having both takes less space than their sizes added up.

For how the models compare in more detail, see [How it works](how-it-works.md#the-3d-models).

## Draw Things & AI

<!-- screenshot: settings-draw-things-ai.png | Settings, Draw Things & AI tab, Draw Things set up (green tick), AI helper for descriptions set to Claude (Anthropic) with an API key saved and "It works." after Test -->

### Set up Draw Things

Draw Things is a free app that lets Mimic draw a character from a description, and turn your
picture into a grey sculpt (which gives better minis). While it isn't set up, this tab shows three
steps that tick themselves off as you do them:

1. **Get Draw Things from the App Store.** It's free. **Open the App Store** takes you there.
2. **Connect Mimic to it.** Mimic does this itself, with Draw Things' command line tool, which comes
   with the 3D engine. Draw Things doesn't even need to be open.
   If that tool is missing, turn on Draw Things' API server instead: in Draw Things, open
   **Settings → Advanced → API Server**, turn it on, choose HTTP and set the port to 7860.
3. **Download FLUX.2 Klein.** In Draw Things' model list, search for FLUX.2 Klein and download it.
   It's big, so give it a few minutes.

Once everything is ready, the tab says **Draw Things is set up.**

### Choose an AI helper for descriptions

The **AI helper for descriptions** is optional and **Off** unless you choose one. With a helper
chosen, New Mini gets an **Improve Description** button that writes a fuller description from a
few words, which you can edit or swap back with **Use Original**. The helper also rewrites what you
type in **What to change** into clear instructions for the redraw.

Pick one under **Helper**:

| Helper | What you fill in |
|---|---|
| **Claude (Anthropic)** | Your API key. **Model** can stay blank, which uses Claude Haiku 4.5: quick and inexpensive. |
| **OpenAI-compatible service** | Your API key, the service's address in **Service address** (blank means OpenAI) and the model's name in **Model**, as the service writes it. |
| **Ollama, on this Mac** | Pick a model from the ones installed. **Refresh** looks again. If none are installed, Mimic says how to get one (`ollama pull gemma3` in Terminal). If a bigger model that follows instructions better is installed, Mimic suggests it with **Use It**. |

For a cloud service, paste your key under **API key** and press **Save**. Mimic keeps it in your
Mac's Keychain and shows **API key saved in your Keychain**, with **Remove** to delete it. A key is
only ever sent to the address it was saved for: change the address and you'll need to save a key
for the new one.

**Test** sends a tiny request and says **It works.**, or what went wrong.

!!! note "What the helper sees"
    A cloud service receives only the text you give it to rewrite, nothing else: no pictures, no
    minis. Ollama runs on your Mac, so with it your descriptions stay there.

## Advanced

<!-- screenshot: settings-advanced.png | Settings, Advanced tab, Time estimates "Based on 12 minis made on this Mac" with Clear…, Start over with Reset Mimic…, and the build line at the bottom -->

### Time estimates

Mimic times every mini it makes to tell you how long the next will take. **Time estimates** says
whether it's using its own figures (until you've made a few minis) or how many of your minis it's
learned from. The times are kept on your Mac only and never sent anywhere.

**Clear…** makes Mimic forget them and go back to its own figures. Your minis are kept.

### Reset Mimic

**Reset Mimic…** puts Mimic back the way it was the first time you opened it, and opens it again.
It asks first:

- **Reset** forgets Mimic's settings, its tips and any saved AI keys, and shows the tour again.
- **Reset All** does the same and also removes the 3D engine, so first-launch setup shows again and
  downloads it again (about 8 GB).

Your minis are always kept, and so is the folder you chose for them. Everything else on these tabs
goes back to how it started, including the 3D model: Mimic goes back to TRELLIS.2. You can't
reset while a mini is being made.

!!! warning
    If you only had Pixal3D downloaded, Mimic shows its welcome screen after a reset, because
    TRELLIS.2 isn't there. Choose Pixal3D on that screen and press **Download**: Mimic checks the
    files you already have instead of downloading them again.

### Which Mimic this is

At the bottom of the tab is the exact version and build of Mimic, like
"Mimic 0.10.0 · build 412 · 1a2b3c4". You can select and copy it. Include it when you report a
problem (Help → **Report a Problem…** adds it for you).

## Not in Settings

- **Mimic → Install Command-Line Tool…** adds the `mimic` command to Terminal. See
  [Mimic from a terminal](cli.md).
- Sizes, nozzle, base and the rest are chosen per mini, in New Mini and Resize. New Mini remembers
  your nozzle, base shape and magnet from last time (a reset forgets them too). See
  [Sizes and bases](sizes-and-bases.md).

## Defaults at a glance

| Setting | Tab | Starts as |
|---|---|---|
| Open Draw Things when needed | General | On |
| Open minis in | General | The first slicer Mimic finds, else the Mac's default app for 3D files |
| Start minis only when plugged in | General | Off (MacBooks only) |
| Your minis are saved in | General | Documents → Mimic |
| Check for updates automatically | General | On |
| 3D model in use | 3D Model | TRELLIS.2 |
| AI helper for descriptions | Draw Things & AI | Off |
