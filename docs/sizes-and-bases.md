# Sizes and bases

How big Mimic makes a mini, what it stands on, and how to change either later. The same choices
are in **New Mini**, **Resize** and **Import a 3D Model**, under **Size & printer**.

Mimic remembers your nozzle, what you size for, and the base's shape, floor and magnet from one
mini to the next, since most people keep one printer and one table.

<!-- screenshot: sizes-and-bases-size-card.png | New Mini sheet, right-hand column only: Size & printer for A character (a mini), Game scale, 0.4 mm · standard nozzle, Scale 32 mm · most common, Base Hex with Stone floor, Advanced opened to show Extra thickness for thin parts, Magnet hole 5 × 2 mm and the variation number -->

## Choose your nozzle

**Nozzle** is the tip your printer prints through:

| Choice | Good for |
|---|---|
| **0.2 mm · fine** | The most detail: sharp faces, beard braids, belt buckles. Slow. |
| **0.4 mm · standard** | Faces and weapons come out clearly; hair and cloth edges get softened. Most printers come with this one. |
| **0.6 mm · fast** | Quick and sturdy, but small details blur. Best at 54 mm scale or bigger. |

Not sure? It's most likely 0.4 mm. Choose the same nozzle in your slicer. The nozzle also sets how
much thin parts are thickened (see [Thin parts](#thin-parts)), and each mini's page shows the slicer
settings for it.

## Size a character for your table

**Size for** has two choices:

- **Game scale** matches the other minis on your table.
- **Best print** goes big enough for faces to come out clearly on your nozzle.

### Game scale

Pick the **Scale** your other minis use, and say **How tall is the character?** in real life.
Mimic works out the mini's height: at 32 mm, an average 1.8 m human stands 32 mm tall, a 2 m
tiefling a little taller, and a 1 m halfling about half that.

| Scale | An average human (1.8 m) | Base |
|---|---|---|
| **28 mm** | 28 mm | 25 mm |
| **32 mm · most common** | 32 mm | 25 mm |
| **35 mm · heroic** | 35 mm | 25 mm |
| **54 mm** | 54 mm | 40 mm |
| **75 mm** | 75 mm | 50 mm |

Type the real height in metres or feet: `1.75`, `1,80`, `5'9"` or `6 ft 2` all work. Leave it
blank for an average human. If Mimic can't read what you typed, it says so under the field and
uses 1.8 m.

A tall character gets a bigger base: about 40% of its height, rounded to 5 mm, and never smaller
than the scale's own base.

!!! tip "Small minis on a 0.4 mm nozzle"
    At 32 mm on a 0.4 mm nozzle, faces come out a little soft. They still print fine. Under
    28 mm (or under 50 mm on a 0.6 mm nozzle) faces turn into bumps, and Mimic warns you. For
    sharper faces, use a 0.2 mm nozzle or choose **Best print**.

### Best print

**Best print** sizes the character so its face comes out clearly on your nozzle:

| Nozzle | Height | Base |
|---|---|---|
| 0.2 mm | 64 mm | 25 mm |
| 0.4 mm | 100 mm | 40 mm |
| 0.6 mm | 150 mm | 60 mm |

Chunky characters also look good a bit smaller.

### Any height you like

**Character height** is filled in for you by the choices above. Drag the slider or type a value
to set your own, anywhere from 15 to 200 mm. It's the character itself, feet to top: the base
adds about 2 mm.

## Choose a base

**Base** has a shape and a floor, side by side, and a size under them.

- **Round**, **Square** or **Hex**. Square and hex bases fit grid and hex maps, and the figure
  faces a flat side.
- **Plain**, or a floor pressed into the top of the base: **Stone floor** (flagstones),
  **Wooden floor** (planks) or **Cobblestones**. The stones or planks are part of the base, so they
  print, and the feet still stand firmly on it.
- **Base size**, from 20 to 80 mm, with marks at 25, 32, 40 and 50 mm. You can type any size.
  For a round base it's the width across; for a square, each side; for a hex, across its flat
  sides. A 25 mm base fits one map square, and a 25 mm hex fits one hex of a 1-inch hex map.

Resize, Try Again and Make Another Version keep the base's shape, floor and magnet.

## Add a magnet hole { #magnets }

Tabletop players often glue magnets under their bases, to hold minis on a steel sheet or in a
tin. Open **Advanced** under **Size & printer** and choose a **Magnet hole**:

- **None**
- **5 × 2 mm**
- **6 × 2 mm**
- **8 × 3 mm**

Each is a round magnet, across by tall. The hole goes up into the bottom of the base with a
little room to spare, and the base gets a little taller to fit it. There's no magnet hole on a
mini without a base.

## Keep thin parts in one piece { #thin-parts }

Swords, staffs and capes can come out thinner than your nozzle can print. Mimic thickens thin
parts to suit your nozzle: **Extra thickness for thin parts**, under **Advanced**.

| Nozzle | Extra thickness |
|---|---|
| 0.2 mm | 0.08 mm |
| 0.4 mm | 0.16 mm |
| 0.6 mm | 0.24 mm |

You can set it yourself, from 0 to 0.40 mm. More keeps swords and capes in one piece, but softens
faces. If a mini still has thin parts that may break, its page says so: check it in your slicer
before printing.

## Keep the character's own base

Some pictures and models already stand on a base or a rock. Under **Advanced**, turn on **Use the
character's own base instead of adding one**: Mimic flattens the bottom of what's there so it
sits on the print bed, and adds no base of its own.

## Size an object

When you make **Anything else** (a teapot, a car, a chess piece), there's no scale to match.
Instead, **Longest side** is its biggest size, whichever way that is: height, width or depth.
Mimic suggests a size that keeps details clear on your nozzle:

| Nozzle | Longest side |
|---|---|
| 0.2 mm | 50 mm |
| 0.4 mm | 80 mm |
| 0.6 mm | 120 mm |

Change it to the size you want. An object stands on its own flat bottom, with no base. Turn on
**Add a base** to give it one: it's sized to sit under the whole object, about 80% of its longest
side (25 to 80 mm), and you can choose its shape, floor, size and magnet as for a character.

## Change the size of a mini you've made

Right-click a mini → **Resize This Mini…** (++cmd+r++), or use **More** on its page. Resize starts
from the sizes the mini has now. Choose new ones and press **Resize**: Mimic makes the print file
again, in about a minute. The mini itself doesn't change: the same shape, at the new size. If a
mini is being made, the resize waits its turn in [the queue](queue.md).

<!-- screenshot: sizes-and-bases-resize-all.png | Resize All in <project> sheet, opened by right-clicking a project of four minis, Game scale at 32 mm · most common, round base, 0.4 mm · standard nozzle, with the explanation under the title visible -->

To resize several at once:

- Select several minis (++cmd++-click or ++shift++-click), then right-click → **Resize N Minis…**.
- Or right-click a project → **Resize All…**.

Choose one size, base and nozzle for all of them, and each mini waits its turn. Each keeps its own
kind of base: an object without a base stays without one. Minis already that size are left out.

!!! tip "The same mini at two sizes"
    Resize replaces the mini's print file. To keep one for the table and one for the shelf,
    right-click it → **Duplicate…** first, then resize the copy. See [Versions](versions.md).

In Terminal it's `mimic resize`, with the same choices as options: see
[Mimic from a terminal](cli.md).

## How much filament it takes

A finished mini's page shows its size and roughly how much filament it needs, under **Size**:

- **Height with base** and **Footprint**, measured from its print file.
- **Filament**, such as "Up to 4 g · 1.3 m": grams of PLA and metres of 1.75 mm filament.

It's worked out for a solid print. Small minis print nearly solid, but infill makes a big one take
less, and supports a little more. Each project shows the total for its minis beside its name.
