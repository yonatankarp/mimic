# Where your files are

Mimic keeps your minis in one ordinary folder you can open in Finder, and everything else (the 3D
engine, the queue, the time estimates) out of your way in Application Support. This page says what
lives where, what each file is, and what you can safely change by hand.

## At a glance

| What | Where |
|---|---|
| Your minis and projects | `~/Documents/Mimic`, or the folder chosen in Settings → General |
| Reports from Report a Problem, and of a crash | `_reports/` in the minis folder |
| The 3D engine and its models | `~/Library/Application Support/Mimic/engine/` |
| The queue | `~/Library/Application Support/Mimic/queues/<key>/` |
| Time estimates | `~/Library/Application Support/Mimic/timings.jsonl` |
| Mimic's settings | the `com.mimic.app` preferences (`defaults read com.mimic.app`) |
| AI helper keys, and the keys for online pictures (account `bfl` for Black Forest Labs, `openai-images` for OpenAI) | your login Keychain, service `com.mimic.app` |
| Mimic's own log | the macOS log, subsystem `com.mimic.app` |

## The minis folder

By default it's **Documents → Mimic** (`~/Documents/Mimic`), made when you make your first mini.
**Settings → General → Open Minis Folder** shows it in Finder.

```text
~/Documents/Mimic/
├── dwarf-cleric/            a mini that isn't in a project ("Unsorted")
├── Tiefling Party/          a project: an ordinary folder
│   ├── tiefling/            a mini in the project
│   ├── tiefling-2/          another version of it
│   └── raven/
├── Orc Warband/             an empty project
└── _reports/                Report a Problem's zips, crash reports' too (never shown as a project)
```

How Mimic reads it:

- **A folder is a mini** when it has a `settings.json`, a `model.glb`, or a print file named after
  the folder (`dwarf-cleric/dwarf-cleric.stl`). Not just any `.stl`: one you drop into a project
  doesn't turn the project into a mini.
- **Any other folder at the top is a project**, empty ones included. Projects are one level deep:
  inside a project only minis count, and other folders are ignored.
- **Folders and files starting with `_` or `.` at the top are Mimic's own** (or hidden) and are
  never minis or projects. `_reports` is one; a Duplicate is put together in a `_duplicate-…`
  folder before it's moved into place.
- **Loose files at the top are ignored.**
- **A mini's folder name is unique across the whole folder**, projects included, and ignoring
  case (your Mac's disk sees "Orcs" and "orcs" as one name). That's the name `mimic` commands take.
  The name shown in the app can be different ("Élodie", "D&D Bard"): it's kept in settings.json.

## A mini's folder

Everything about one mini is in its folder. For a mini called `tiefling`:

| File | What it is |
|---|---|
| `tiefling.stl` | The print file: what **Open in …** and your slicer open. Its name always matches the folder's. |
| `tiefling_front.png`, `_left.png`, `_right.png`, `_back.png` | The four previews: grey, 900 × 900, on a transparent background. Older minis may have a `_side.png` instead of left and right until they're resized. |
| `source.png` | The picture the 3D model was built from: your picture copied, or the one Draw Things (or the online service you chose) drew or redrew as a grey sculpt. |
| `upload.img` | The picture you gave it, turned upright, no larger than 2048 pixels on its longest side, saved as PNG. Only for minis made from a picture. |
| `upload-back.img`, `source-back.png` (and `-left`, `-right`) | The same, for pictures of the back and sides. |
| `source__matted.png` | `source.png` cut out from its background, which is what the 3D engine sees. |
| `model.glb` | The 3D shape the 3D engine made, before print prep, with the engine's colours. Resize, Duplicate and Export for Virtual Tabletop start from it. |
| `placement.json` | Where print prep put `model.glb` to make the print file: see [below](#placementjson). Made again with the print file. |
| `settings.json` | How the mini was made and what it was asked for: see below. |
| `generate.job.log` | The steps of the last make or Try Again: `[1/3] Getting the picture ready`, `[2/3] Building the 3D shape`, `[3/3] Making the print-ready file`. |
| `prep.job.log` | The same for the last job that only ran print prep: a resize, an import, or a Try Again that only needed print prep. |
| `pixal3d.log` | What the 3D engine said, for either 3D model. Where a failure in step 2 shows. |
| `prep.log` | What print prep did, with sizes, how many loose pieces it dropped and any warnings. See [Tuning print prep](print-prep.md#what-it-says). |
| `model.ply`, `model_base.png`, `model.svviews/` | Left by the 3D engine as it works. Mimic doesn't use them afterwards. |
| `model.mvviews/` | The cut-out pictures handed to TRELLIS.2 when a mini has pictures of its back and sides (`1-front.png`, `2-back.png`, …). |

You may also see, briefly:

- `tiefling.part.stl` while print prep writes the print file; it replaces `tiefling.stl` in one go.
- `prep-result.json`, which print prep writes for the job to read, and which goes as soon as the
  job has read it.

### settings.json

Written the moment a mini is asked for, and updated as it's made. The fields you're most likely to
look at:

| Field | What it holds |
|---|---|
| `name` | The name as typed ("Élodie"). Shown only while the folder still has the name it was given for (`nameFolder`). |
| `source` | `image` or `desc`. |
| `desc`, `descOriginal` | The description drawn from, and what you typed when the AI helper's version was used. |
| `restyle`, `cartoon`, `kind` | The grey sculpt, a cartoon, and `object` for anything that isn't a character. |
| `seed`, `shapeSeed` | The variation number, and the 3D shape's own number after New 3D Shape. |
| `model` | The 3D model it was made with (`trellis2-q8` or `pixal3d-sv`). Try Again uses it. |
| `requested`, `made` | The sizes asked for and the sizes the last finished run made: `height`, `base`, `nozzle`, `inflate`, `nobase`, `shape`, `style`, `magnet`, as text. |
| `sides`, `fixes`, `imported`, `versionOf` | Pictures of the back and sides, what was changed in the picture, the file a model was imported from, and the first of its versions. |
| `failed`, `failedStep`, `notes`, `fragile` | Why the last run didn't finish, and what the last finished run wants you to know. |
| `created` | When it was asked for: the list's order. |

For scripts, `mimic info <name> --json` gives the same in a form that won't change: see
[JSON for scripts](cli.md#json-for-scripts).

### placement.json

Print prep writes it beside the print file each time it makes one, to say how it moved the 3D
engine's model onto the base: turned round (Pixal3D's models face the other way), levelled and set
on a side (an object), scaled, centred, sunk into the base and lowered by the flattened bottom.
That's all one matrix, row by row, in millimetres:

```json
{"matrix": [[-1.6, 0, 0, 0.2], [0, -1.6, 0, -0.3], [0, 0, 1.6, 2.4], [0, 0, 0, 1]]}
```

A point (x, y, z) of `model.glb`, read with z up the way Blender imports it, lands on the print file
at the matrix times (x, y, z, 1). Export for Virtual Tabletop uses it the other way round: for each
part of the print file, it looks straight into the surface for `model.glb` and takes its colour
there. Print prep pushes the surface out a little to keep thin parts whole, so the nearest point on
`model.glb` would often be the edge of a raised strand of hair or a necklace beside it, and widen
it into a smear. Where looking straight in finds nothing close by, it takes the nearest point's
colour.

A mini whose print file was made before Mimic kept this file has none. Its export is still in
colour: Mimic works out the same placement from the mini's settings, as print prep would now.

## Application Support

`~/Library/Application Support/Mimic/` holds what Mimic downloads and keeps for itself:

```text
~/Library/Application Support/Mimic/
├── engine/
│   ├── trellis-cli          the 3D engine (pixal3d.cpp, built for Metal)
│   ├── libggml*.dylib       its libraries
│   ├── VERSION              which build it is; Settings asks for a Repair if it's not the one Mimic expects
│   ├── LICENSE-*            its licences
│   ├── draw-things-cli      Draw Things' command line tool
│   └── models/
│       ├── trellis2-q8/     TRELLIS.2's files (9.1 GB)
│       └── pixal3d-sv/      Pixal3D's files (8.1 GB)
├── queues/
│   └── 1a2b3c4d5e6f7a8b/    one queue per minis folder
└── timings.jsonl            how long your minis took
```

- **engine/** is everything setup downloads. A file still downloading is `<name>.part` and resumes
  from where it stopped. Delete the whole folder and Mimic downloads it again (Settings → Advanced
  → Reset Mimic… → **Reset All** does that for you).
- **queues/** has a folder for each minis folder, named after the first 16 hex digits of the
  SHA-256 of that folder's path. Inside: `queue.json` (the minis waiting, oldest first), `job.json`
  and `job.pid` (the mini being made and which Mimic is making it), the lock files `queue.lock` and
  `job.lock`, and while they apply, `paused` (the queue is paused), `job.stop` (`mimic stop` asking)
  and `moving` (the minis folder is being moved). A `queue.json` that won't read (damaged, or from
  a newer Mimic) is never written over: it's renamed to `queue.json.unreadable-<date and time>`, as
  it was, and a new queue starts. You can delete those copies. The queue isn't in the minis folder
  so that two Macs sharing it through iCloud never share a queue.
- **timings.jsonl** has one line per mini made on this Mac (the Mac, the model, the sizes and each
  step's time), at most 2,000 lines. It's what time estimates are learned from, and it's never
  sent anywhere. Settings → Advanced → **Clear…** empties it.

## What's safe to change in Finder

Mimic watches the minis folder and picks up what you do in Finder. These are fine:

- **Make, rename or delete a project folder.** It's just a folder. Mimic shows the change. Leave it
  alone while one of its minis is being made.
- **Move a mini's folder into a project, out of one, or between them.** Not while that mini is being
  made or waiting in the queue.
- **Rename a mini's folder.** Mimic takes it over: a name with capitals, spaces or accents gets a
  plain folder name (`Élodie la Druide` becomes `elodie-la-druide`) and is shown as you typed it,
  and the files inside are renamed to match. A copy (`dwarf-cleric copy`) becomes a mini of its
  own, `dwarf-cleric-copy`.
- **Put your own files in a project folder** (notes, a slicer project). Mimic ignores them, and
  keeps them when it moves or deletes the project (a deleted project's folder goes to the Trash).
- **Move a mini to the Trash.** You can put it back from the Trash.

Best avoided:

- **Renaming files inside a mini's folder.** Mimic finds the print file and previews by the folder's
  name.
- **Editing settings.json by hand.** If it no longer reads, Mimic leaves it alone and says so rather
  than overwriting it, but the mini can't be resized or made again until it's fixed.
- **Changing anything in a mini that's being made.**

## Backups and moving the minis folder

Everything that's yours is in the minis folder: back that up and you have every mini, its picture and
how it was made. The engine and models (8 to 9 GB for each model) don't need backing up: Mimic can
download them again.

To move the folder, use **Settings → General → Change…** rather than Finder: it can move every mini
and project for you (**Move Minis**) or start using a folder that already has minis
(**Don't Move**). See [Settings](settings.md#choose-where-your-minis-are-kept).
If you move or rename the chosen folder in Finder, Mimic goes back to `~/Documents/Mimic` until you
choose it again.

The minis folder can be on another disk or in iCloud Drive. The queue is never in it, so iCloud
never syncs a queue between Macs.

## The dev build's folders

*Mimic Dev*, the app `app/bundle.sh` builds (see [CONTRIBUTING.md](https://github.com/yonatankarp/mimic/blob/main/CONTRIBUTING.md)), is a separate app
with its own settings (`com.mimic.app.dev`), so it never touches the Mimic you use. `bundle.sh` sets
its `installDir` to the checkout, so it keeps:

| What | Where |
|---|---|
| Minis | `runs/` in the checkout (or a folder chosen in its own Settings) |
| 3D engine and models | `engine/` in the checkout |
| Queue | `~/Library/Application Support/Mimic/queues/<key>/`, keyed by its minis folder and shared with any Mimic using the same one |
| Time estimates | `~/Library/Application Support/Mimic/timings.jsonl`, the same file as the installed app |

Run from a terminal, two environment variables change that:

- **`MIMIC_HOME=<folder>`** uses `<folder>/runs`, `<folder>/engine`, `<folder>/queue` and
  `<folder>/timings.jsonl`, all inside it, and Settings can't change the minis folder.
- **`MIMIC_FAKE_HOME=<folder>`** treats `<folder>` as the home folder of a Mac that has never run
  Mimic, for trying first launch.

`runs/`, `engine/` and `queue/` are git-ignored.
