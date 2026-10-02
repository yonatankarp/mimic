# Mimic from a terminal

Everything Mimic does in its window, it also does as a `mimic` command in Terminal, with the same
engine and the same minis. It's handy for making a batch of minis from a script, resizing a whole
project in one go, or reading your minis as JSON.

## Install it

1. Finish Mimic's first-launch download in the app: `make` and `retry` need the 3D engine.
2. Choose **Mimic → Install Command-Line Tool…**, copy the command it shows, and paste it into
   Terminal. It asks for your Mac password once.
3. Check it works:

```bash
mimic --version
```

`mimic --help` lists every command and option.

## Make your first mini

Give it a name and a description, or a picture:

```bash
mimic make "Dwarf Cleric" "dwarf cleric, warhammer held against chest"
mimic make tiefling --image art.png --restyle
```

The name can be anything, as in the app. Terminal shows each step while the mini is made and says
where its print file is when it's done. `--restyle` turns the picture into a grey sculpt first,
like **Turn it into a grey sculpt first** in New Mini. Ctrl-C stops the mini and everything it
started.

If Mimic is already making another mini, in the app or another Terminal, yours joins the
[queue](queue.md) and the command returns straight away. Add `--wait` to stay and watch it instead.

## Choose its size, base and nozzle

The same choices as [Sizes and bases](sizes-and-bases.md), as options:

```bash
mimic make tiefling --image art.png --height 38 --nozzle 0.2 --base-shape hex --base-style stone
mimic make teapot "a round teapot with a curved spout" --object --size 80
```

`--object` makes anything that isn't a character: no base, sized by its longest side. Every option
is in the [table below](#every-option).

## Resize a mini, or a whole project

```bash
mimic resize tiefling --height 32 --base 25
mimic resize --project "Tiefling Party" --height 32
```

Only print prep runs again, so a resize takes about a minute. With `--project`, every mini in the
project gets the new size, like **Resize All…**.

## Make another version

```bash
mimic retry tiefling                    # carry on from the step that failed
mimic make-another tiefling             # the same, with a new seed: "tiefling-2"
mimic make-another tiefling --new-shape # keep its picture, make only the 3D shape again
mimic make-another tiefling --change "close the cape so both arms show"
mimic keep tiefling-2                   # keep this one, move the other versions to the Trash
```

These match [Versions](versions.md) in the app. `--change` redraws the picture with your change
first; in Terminal it carries straight on to the 3D shape, where the app stops to show you the
picture.

## Copy, import and export

```bash
mimic duplicate tiefling --as "Tiefling Display"   # the same shape, to resize separately
mimic import "Ogre Chief.stl" --height 32          # print prep for a GLB or STL made elsewhere
mimic open tiefling                                # open its print file in your slicer
mimic export tiefling --vtt                        # a low-poly .glb for a virtual tabletop
```

`export` saves the `.glb` in the folder you're in. See [Printing and exporting](printing.md) for
when it comes out in colour.

## Find, rename and organise your minis

```bash
mimic list                                  # every mini, by project
mimic info tiefling                         # its size, filament, how it was made and its versions
mimic rename tiefling --to "Tiefling Warlock"
mimic trash tiefling-3                      # to the Trash, where you can put it back
mimic project create "Orc Warband"
mimic move tiefling --project "Orc Warband" # or --unsorted
mimic project delete "Orc Warband"          # its minis go to Unsorted; --trash-minis trashes them
```

A mini goes by its name in `mimic list`, or by the name you gave it in Mimic:
`mimic info "Élodie"`. Changes show in the app straight away. See
[Your minis and projects](organizing.md).

## Watch and change the queue

```bash
mimic queue                         # the mini being made and the ones waiting
mimic queue move raven --to front   # or --to end, --to 3, --up, --down
mimic queue remove raven
mimic queue pause                   # no new mini starts until: mimic queue resume
mimic stop                          # stop the mini being made, in Mimic or another Terminal
```

There's one queue for the app and every Terminal. See [The queue](queue.md).

## Every option

Not every command takes every option. The size options are shared by `make`, `resize` and
`import`; the rest belong to one or two commands each.

### Size options

For `make`, `resize` (one mini or `--project`) and `import`.

| Option | What it does |
|---|---|
| `--height MM` | How tall the character is, feet to top; the base adds about 2 mm |
| `--size MM` | For an object, its longest side (set from the nozzle unless you give it); for a character, the same as `--height` |
| `--scale 28` / `32` / `35` / `54` / `75` | Match the scale your other minis use: sets the height and base for an average human (`--height` and `--base` still win). Characters only |
| `--base MM` | Size of the base: across it, or across the flat sides for a hex |
| `--base-shape round` / `square` / `hex` | The base's shape (round unless you give it) |
| `--base-style plain` / `stone` / `wood` / `cobble` | A floor pressed into the top of the base: flagstones, planks or cobblestones (plain unless you give it) |
| `--magnet 5x2` / `6x2` / `8x3` / `none` | A hole under the base for a round magnet this wide by this tall, in mm, with a little room to spare; the base gets taller to fit it (none unless you give it) |
| `--nozzle 0.2` / `0.4` / `0.6` | Your printer's nozzle |
| `--inflate MM` | Extra thickness for thin parts (set from the nozzle unless you give it) |
| `--no-base` | Keep the character's own base instead of adding one |
| `--add-base` | Give an object a base too (sized to its shadow unless you give `--base`) |

A resize keeps the mini's base shape, floor, magnet and nozzle unless you give them.

### `mimic make`

`mimic make "<name>" "<description>"` or `mimic make "<name>" --image <picture>`, plus the size
options and:

| Option | What it does |
|---|---|
| `--image FILE` | Start from your own picture instead of a description |
| `--restyle` | Redraw that picture as a grey sculpt first (its tabletop export is then grey) |
| `--back FILE` / `--left FILE` / `--right FILE` | With `--image` (the front): pictures of the same character from the back and sides, so the 3D model doesn't guess them. Any of them; TRELLIS.2 only |
| `--change "TEXT"` | With `--image`: redraw the picture with this change first, e.g. `"close the cape so both arms show"`. It gets the grey sculpt too |
| `--improve` | With a description: let the AI helper chosen in Settings write a fuller one first |
| `--object` | Make anything that isn't a character: no base, sized by its longest side, set on its flat bottom |
| `--seed N` | Try a different version of the same character (42 unless you give it) |
| `--model ID` | Make it with this 3D model instead of the one chosen in Settings (`mimic models` lists them) |
| `--project NAME` | Put it in that project; a new one is made if needed |
| `--wait` | If another mini is being made, stay until this one is made, instead of returning once it's in the queue |

### `mimic make-another`

`mimic make-another <name>` makes the next version, with the mini's own picture or description and
sizes.

| Option | What it does |
|---|---|
| `--new-shape` | Keep the picture it made and make only the 3D shape again |
| `--change "TEXT"` | Redraw the picture with this change first. It starts from the picture this mini was made from, so changes add up. In Terminal it carries straight on; the app stops to show you the picture first |
| `--seed N` | Use this seed instead of a new one |
| `--wait` | As for `make` |

### `mimic resize`

`mimic resize <name>`, or `mimic resize --project "<project>"` for every mini in a project (like
**Resize All…**). Takes the size options and `--wait`.

### `mimic retry`

`mimic retry <name>` carries on from the step that failed. Takes `--wait`.

### `mimic import`

`mimic import <file.glb|file.stl>` takes the model as it is. Takes the size options, `--object`,
`--project NAME` and `--wait`.

### Other commands

| Command | Options |
|---|---|
| `mimic duplicate <name>` | `--as "<new name>"`, the copy's name (needed) |
| `mimic export <name>` | `--vtt` (needed), and `--triangles N` for how many triangles the low-poly model has (5,000 unless you give it) |
| `mimic rename <name>`, `mimic project rename "<project>"` | `--to "<new name>"` (needed) |
| `mimic move <name>` | `--project "<project>"` or `--unsorted` |
| `mimic project delete "<project>"` | `--trash-minis` moves its minis to the Trash too, instead of to Unsorted |
| `mimic queue move <name>` | `--to front`, `--to end`, `--to <place>`, `--up` or `--down` |
| `mimic list`, `projects`, `queue`, `models`, `info <name>` | `--json` prints it as JSON, for scripts ([below](#json-for-scripts)) |

## JSON for scripts

`mimic list --json`, `projects --json`, `queue --json`, `models --json` and `info <name> --json` print JSON. These
field names stay as they are: new ones may be added, but none is renamed or removed. Dates are
ISO 8601 (`2026-09-21T14:13:20Z`), sizes are millimetres and times are seconds. A field with no
value is left out.

- `list`: an array of minis, every project's, newest first. Each has `name` (what `mimic`
  commands take), `shown` (the name it's shown as), `project` (left out when unsorted), `state`
  (`ready`, `unfinished` or `waiting`), `kind` (`character` or `object`), `created`, `file` (its
  print file, once made) and `folder`.
- `projects`: an array of `name` and `minis` (how many are in it), by name.
- `queue`: `running` (`name`, `job` of `make` or `resize`, `step` 1 to 3, `started`,
  `secondsLeft`), `held` (`paused` or `battery`, when the next one waits for that) and `waiting`,
  an array of `place` (from 1), `name`, `job`, `added`, `seconds` (how long it takes) and
  `readyIn`.
- `models`: an array of `id`, `name`, `bytes`, `downloaded`, `selected` (the one Mimic uses) and
  `about`.
- `info`: `mini` (as in `list`), `made` (`height`, `base`, `nozzle`, `inflate`, `noBase`, `shape`,
  `style`, `magnet`), `measured` (`height` with its base, `width`, `depth`, `filamentGrams`,
  `filamentMetres`), `madeFrom` (`source` of `picture` or `description`, `description`, `typed`,
  `seed`, `shapeSeed`, `model`, `greySculpt`, `cartoon`), `versions` (names, itself included) and
  `failed` (why its last run didn't finish).

## Completing as you type

`mimic completions zsh`, `bash` or `fish` prints a script that completes commands, options, their
choices, and your minis' and projects' names as you press Tab. Add it once:

| Shell | Add this |
|---|---|
| zsh (the Mac's) | `source <(mimic completions zsh)` at the end of `~/.zshrc` |
| bash | `eval "$(mimic completions bash)"` at the end of `~/.bash_profile` |
| fish | Run `mimic completions fish > ~/.config/fish/completions/mimic.fish` once |

Then open a new Terminal window. In zsh it needs completion turned on, which most setups already
have; if Tab does nothing, put `autoload -Uz compinit && compinit` above that line.
