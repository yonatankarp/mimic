# Tuning print prep

Print prep is the last step of every mini: it turns the 3D engine's model into a print-ready STL,
sized, on a base, in one solid piece, with its previews. This page says what it does step by step,
which options it takes, and how to run it by hand to try settings the app doesn't offer.

It's Mimic's own Swift code (`app/Sources/MimicCore/Prep.swift`, whose header lists every option),
run as a separate program so **Stop** can end it like any other step. It replaced a Blender script:
on the dwarf (32 mm, 25 mm base, 0.2 mm nozzle) Blender took 58 s and 6.0 GB of memory, print prep
takes 6 s and 1.5 GB. At 100 mm on a 0.4 mm nozzle, 157 s and 13.2 GB against 14 s and 2.9 GB.

## What it does, step by step

1. **Reads the model** (`model.glb`, written by the 3D engine or by File → Import Model…).
2. **Turns it to face the front** (`--turn`), the way a slicer's front view looks at it. Pixal3D
   builds figures facing the other way from TRELLIS.2, so Mimic turns them 180°.
3. **Stands an object up** (objects only, `--ground bottom`). A model that leans a few degrees is
   levelled by up to 30°, then set on a side it can stand on: see
   [Objects resting on a flat side](#objects-resting-on-a-flat-side).
4. **Refuses a flat sheet.** If its thinnest side is under 2% of its longest, print prep stops with
   "The 3D model came out flat, like a sheet of paper." A flat drawing needs the grey sculpt.
5. **Scales it.** A character is scaled so `--height` is the distance from the ground to its top.
   The ground is where most of the bottom is (0.5% of the surface lies below it), not the lowest
   point, so a trailing wisp sinks into the base rather than holding the figure up on a pin. An
   object (`--fit longest`) is scaled so its longest side, whichever way it runs, is `--height`.
   Floating specks don't count towards it.
6. **Centres it.** A character is centred on the solid cross-sections through its lower body (at 3,
   6, 9 and 12% of its height), so a raised sword or a cape doesn't pull it off the base. An object
   is centred on its whole shadow. This is also where it measures the footprint: how far the
   figure reaches out near its feet.
7. **Sinks the feet 0.6 mm into the base**, so the two are one solid.
8. **Makes one solid.** The model becomes a signed distance field on a grid `--voxel` apart, built in
   slabs so memory follows the surface rather than the whole box, and one surface is drawn from it
   with marching cubes, so the result is closed and manifold by construction. In the same field it:
    - **inflates** the surface by `--inflate`, a true offset that thickens blades, staffs and capes
      by twice that;
    - adds the **base**: round, square or hex, `--base` across (across the flats for a hex),
      `--base-height` tall, with a rounded top edge;
    - presses a **floor** into the base's top for `--base-style` (seams 0.45 mm deep);
    - cuts the **magnet hole** underneath;
    - cuts everything below `--flatten` off, so the bottom is flat however bumpy the model's own
      base was.
9. **Keeps the largest piece** and drops the rest: see [Parts left out](#parts-left-out).
10. **Lowers it by `--flatten`**, so the bottom of the base is at zero.
11. **Trims it to about `--faces` triangles** (800,000), by collapsing edges in a way that never
    breaks the solid. A base with a floor gets a sixteenth more, for its seams.
12. **Draws the previews**: front, left, right and back, grey, 900 × 900, on a transparent
    background, beside the print file. They're drawn in software, so they don't compete with the
    3D engine for the graphics chip. They come before the STL on purpose: a resize stopped while
    they're drawn keeps the old print file.
13. **Writes the STL**, to a `.part.stl` first, then puts it in place in one go.
14. **Notes where it put the model** in `placement.json` beside the STL: one matrix for the turn,
    the levelling, the scale and every shift, from the 3D model to the print file. Export for
    Virtual Tabletop reads it to find each part's colour on the 3D model. See
    [Where your files are](files.md#placementjson).
15. **Says how it went**: the size, how many loose pieces it dropped, and any warnings. See
    [What it says](#what-it-says).

## The options

```text
mimic _prep in.glb out.stl [--height 32] [--base 25] [--base-height 3] [--nozzle 0.4]
    [--inflate MM] [--voxel MM] [--faces 800000] [--no-base] [--flatten 0.4]
    [--fit height|longest] [--ground feet|bottom] [--turn DEG] [--base-shape round|square|hex]
    [--base-style plain|stone|wood|cobble] [--base-seed N] [--magnet 5x2|6x2|8x3|none]
```

Sizes are millimetres.

| Option | Default | What it does |
|---|---|---|
| `--height MM` | 32 | Figure height, ground to top. With `--fit longest`, the longest side. |
| `--fit height` / `longest` | `height` | Size by the height, or by the longest side (objects). |
| `--ground feet` / `bottom` | `feet` | Centre on the feet's cross-sections, or on the whole shadow (objects). `bottom` also levels the model and stands it on a steady side. |
| `--base MM` | 25 | Base width: a round base's diameter, a square's side, a hex's width across the flats. |
| `--base-shape` | `round` | `round`, `square` or `hex`. A square or hex faces the figure with a flat side. |
| `--base-style` | `plain` | `plain`, or a floor pressed into the top: `stone` (flagstones), `wood` (planks) or `cobble` (cobblestones). |
| `--base-seed N` | 0 | Lays out the floor's stones or planks. |
| `--base-height MM` | 3 | The base before the bottom is cut flat: 3 mm prints as 2.6 mm, of which the feet take 0.6. Raised to fit a magnet hole. |
| `--magnet` | `none` | A hole underneath for a round magnet: `5x2`, `6x2` or `8x3` (across × tall, mm). |
| `--no-base` | off | No base: keep the model's own. No magnet hole either. |
| `--nozzle MM` | 0.4 | Your printer's nozzle. Sets `--inflate`, `--voxel`, the magnet hole's room and the floor's seams. |
| `--inflate MM` | 0.4 × nozzle | How far the surface is pushed out. More keeps thin parts whole; too much softens faces. |
| `--voxel MM` | nozzle ÷ 4 | Grid spacing. Smaller keeps more detail and takes much more time and memory. |
| `--flatten MM` | 0.4 | How much is sliced off the bottom. |
| `--faces N` | 800000 | About how many triangles the STL keeps. |
| `--turn DEG` | 0 | Turns the model about its vertical axis first. |

Anything else is refused ("unknown option"), and a number has to be 0 or more.

### How the nozzle feeds in

The nozzle you pick in New Mini or Resize (`--nozzle` in Terminal) sets the rest unless you set them
yourself:

| Nozzle | Extra thickness (`--inflate`) | Grid (`--voxel`) | Magnet hole room | Floor seams |
|---|---|---|---|---|
| 0.2 mm | 0.08 mm | 0.05 mm | +0.2 mm | 0.4 mm wide |
| 0.4 mm | 0.16 mm | 0.1 mm | +0.2 mm | 0.8 mm wide |
| 0.6 mm | 0.24 mm | 0.15 mm | +0.3 mm | 1.2 mm wide, stones 1.5 × larger |

The inflate of 0.4 × nozzle was tuned on a 0.2 mm nozzle, where 0.08 mm keeps cloth whole and
0.15 mm already looked melted. A wider nozzle drops thinner walls, so it gets more. A grid of a
quarter of the nozzle is finer than any line the printer can make. A fixed 0.05 mm made a 100 mm
figure on a 0.4 mm nozzle take many minutes and 8 GB.

In the app, the inflate is **Extra thickness for thin parts**, under **Size & printer → Advanced**
in New Mini and Resize (0 to 0.4 mm). Mimic sends it only once you've moved it; otherwise print
prep works it out from the nozzle. In Terminal it's `--inflate`.

### Magnets

The hole is the magnet's width plus room for the nozzle (a printed hole comes out a little smaller
than drawn), and its height plus 0.2 mm for glue, up from the bottom. At least 0.8 mm of solid is
kept over it, so the base grows when it has to:

| Magnet | Hole (0.2 or 0.4 mm nozzle) | Base height, plain top | With a floor |
|---|---|---|---|
| 5 × 2 mm | 5.2 mm wide, 2.2 mm deep | 3.4 mm | 3.85 mm |
| 6 × 2 mm | 6.2 mm wide, 2.2 mm deep | 3.4 mm | 3.85 mm |
| 8 × 3 mm | 8.2 mm wide, 3.2 mm deep | 4.4 mm | 4.85 mm |

The base heights are before the bottom is cut flat, as `--base-height` is.

## What Mimic passes

Mimic runs print prep with the sizes saved in the mini's `settings.json` (`requested`) and adds
what the mini needs:

| Flags | When |
|---|---|
| `--height`, `--base`, `--nozzle` | Whatever was chosen. A mini made in Terminal without sizes gets print prep's defaults. |
| `--inflate` | Only when it was set by hand. |
| `--no-base`, or `--base-shape`, `--base-style`, `--magnet` | Only when they aren't the default. |
| `--fit longest --ground bottom` | For anything that isn't a character. |
| `--turn 180` | For a mini made with Pixal3D. Never for an imported model, which faces whichever way its file has it. |
| `--base-seed N` | With a floor on the base: the mini's own variation number (42 if it has none), so Try Again lays the stones the same way and another version differently. |

So a TRELLIS.2 tiefling at 38 mm on a 0.2 mm nozzle, on a hex base with a stone floor, runs:

```bash
mimic _prep model.glb tiefling.stl --height 38.0 --base 25.0 --nozzle 0.2 \
    --base-shape hex --base-style stone --base-seed 42
```

## Run it by hand

`mimic _prep` is a hidden command: it isn't in `mimic --help`, it's for experimenting, and its options
may change between versions. With the command-line tool installed (see
[Mimic from a terminal](cli.md)) it's `mimic _prep`; without it, run the app's own binary,
`/Applications/Mimic.app/Contents/MacOS/mimic _prep`.

!!! warning
    Work on a copy, never in a mini's own folder. Print prep overwrites the STL, its previews and
    `placement.json`, and leaves a `prep-result.json` beside them. To give a mini new sizes, use **Resize This Mini…** or
    `mimic resize` instead.

```bash
mkdir -p ~/Desktop/prep-test
cp ~/Documents/Mimic/dwarf-cleric/model.glb ~/Desktop/prep-test/
cd ~/Desktop/prep-test
mimic _prep model.glb dwarf.stl --height 32 --nozzle 0.2 --turn 180 --faces 400000
```

Add `--turn 180` when the mini was made with Pixal3D (its `settings.json` says
`"model": "pixal3d-sv"`, or has no `model` at all); leave it out for TRELLIS.2. The input has to
be a GLB: for an STL, import it with File → Import Model… or `mimic import` first, and use the
`model.glb` that makes.

It writes `dwarf.stl`, `dwarf_front.png`, `dwarf_left.png`, `dwarf_right.png`, `dwarf_back.png`,
`placement.json` and `prep-result.json`, and prints what it did. It exits with 0 when it worked, or prints
`mini_prep: FAILED: …` and exits with 2.

Things worth trying that the app doesn't offer:

- `--voxel` smaller than nozzle ÷ 4, for a large display piece on a fine nozzle. Time and memory
  grow fast.
- `--faces` lower, for a smaller file to share, or higher, to keep more of a big figure's detail.
- `--flatten` higher, when a model's own base is very uneven and you used `--no-base`.
- `--base-height` taller, for a chunkier base.

## What it says

Print prep's report goes to the mini's `prep.log`, with how long each part took. For example (times
and sizes vary):

```text
prep: read 980630 triangles 0.1 s
prep: placed 0.1 s
prep: solid 289x262x516 grid, 2237348 triangles 0.6 s
prep: largest piece 0.2 s
prep: trimmed to 800000 triangles 1.1 s
prep: drew the previews 1.0 s
prep: written 0.0 s
mini_prep: …/dwarf-cleric.stl  size 28.3 x 25.5 x 51.2 mm  faces 800000  loose pieces dropped 150  footprint 20.2 mm
```

Other lines it may add:

| Line | Meaning | Shown in the app as |
|---|---|---|
| `prep: levelled by 2.8°` | An object was levelled. | Nothing. |
| `prep: set on its most stable side (turned 90°)` | An object was set on another side. | Nothing. |
| `mini_prep: magnet hole 5.2 mm wide, 2.2 mm deep, for a 5 × 2 mm magnet; base 3.40 mm tall` | The hole, and the base height it needed. | Nothing. |
| `mini_prep: no base, so no magnet hole` | A magnet was asked for without a base. | Nothing. |
| `mini_prep: WARNING footprint 41.3 mm is wider than the 40 mm base; raise the base to at least 43 mm` | The figure reaches out past its base. | "The bottom of the figure reaches past the edge of its base. Resize This Mini with a bigger base size to fit it on." |
| `mini_prep: WARNING part: …` | A part was left out. | The same words, on the mini's page. |
| `mini_prep: WARNING stand: …` | An object without a base can't stand. | The same words, on the mini's page. |
| `mini_prep: FAILED: …` | Print prep stopped. | Why the mini didn't finish. |

An object on a base never gets the footprint warning: its base is a plinth, sized to its shadow.

The app doesn't read `prep.log`: it reads the same warnings from `prep-result.json`, so rewording a
log line changes nothing it shows. A mini's page keeps showing the last run's warnings, after a
relaunch too, until a resize replaces them.

## Objects resting on a flat side

Anything that isn't a character goes through two more steps before it's sized:

1. **Levelling.** The downward-facing surface in its lowest tenth is turned to face straight down,
   in up to three passes. More than 30° is more likely an object lying on its side on purpose than
   a lean, so that's left alone. A teapot the 3D engine leaned 5° prints on its foot, not on the
   edge of it.
2. **Resting.** Its possible sides are the faces of its convex hull (built from the main pieces
   only, so floating specks don't hold it up), where hull faces lying within 3° of each other count
   as one side. It stands on a side if it survives an 8° tilt there. If it already stands on a
   side within 10° of straight down, it's left as it is, however much steadier lying down would be:
   a vase, a pillar or a statue with a flat back is never laid down. Otherwise it goes onto the
   steadiest side within 30° of down, and never further.

If no side near its bottom can hold it up (a figure on small feet, a bird on a perch), the levelling
is undone too and it stays exactly as the 3D engine made it. Without a base it then gets the
"can't stand on its own" warning; with **Add a base** it stands on the base. Characters never go
through any of this: they stand on their feet.

## Parts left out

Print prep keeps only the largest connected piece. The rest are of two kinds, told apart by the
sign of their volume rather than their size:

- **The inner walls of hollows.** A hollow's inner surface is a piece of its own, inside out, so its
  volume is negative. Dropping it fills the hollow. These can be big (a whole body's length).
- **Solid pieces.** Mostly specks the 3D engine left floating, but sometimes something the figure
  holds that the engine didn't join to its hands. A solid piece at least a tenth of the figure's
  height long is counted as a part. It's still left out, because it would print floating where the
  hands held it, needing supports and glue. But Mimic says so: "A part came out separate from the
  figure (about 30 mm long) and was left out. Try Make Another Version. If you use Pixal3D,
  TRELLIS.2 (Settings → 3D Model) joins held things more reliably."

The tenth was measured: a lost bow was 93% of its figure's height, and the largest solid speck on
seven real minis was under 1%. In the comparison that made TRELLIS.2 the default, it got the held
part right 9 times out of 9, against 4 out of 10 for Pixal3D.
