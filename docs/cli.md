# Mimic from a terminal

The app is also a `mimic` command, with the same engine. To add it to your Terminal, choose
**Mimic → Install Command-Line Tool…**, copy the command it shows and paste it into Terminal (it asks
for your Mac password once). Finish the app's first-launch download first: `make` and `retry` need it.

```bash
mimic make "Dwarf Cleric" "dwarf cleric, warhammer held against chest"  # any name, as in the app
mimic make tiefling --image art.png --restyle --height 38 --nozzle 0.2
mimic resize tiefling --height 32 --base 25
mimic make teapot "a round teapot with a curved spout" --object --size 80
mimic retry tiefling
mimic make-another tiefling                        # the same, with a new seed: "tiefling-2"
mimic make-another tiefling --new-shape            # keeps its picture, makes only the 3D shape again
mimic duplicate tiefling --as "Tiefling Display"   # the same shape, to resize without losing the first
mimic import "Ogre Chief.stl" --height 32          # print prep for a model made elsewhere (GLB or STL)
mimic make raven --image raven.png --project "Tiefling Party"
mimic move tiefling --project "Tiefling Party"     # or --unsorted
mimic resize --project "Tiefling Party" --height 32 # Resize All: every mini in the project
mimic open tiefling                                # in your slicer
mimic export tiefling --vtt                        # a low-poly .glb for a virtual tabletop, in this folder
mimic info tiefling                                # its size, filament, how it was made and its versions
mimic rename tiefling --to "Tiefling Warlock"
mimic keep tiefling-2                              # keeps this version, moves the others to the Trash
mimic trash tiefling-3                             # to the Trash, where you can put it back
mimic stop                                         # stops the mini being made, in Mimic or another Terminal
mimic project create "Orc Warband"
mimic project rename "Orc Warband" --to "Orc Horde"
mimic project delete "Orc Horde"                   # its minis go to Unsorted; --trash-minis trashes them too
mimic projects
mimic list
mimic models                                       # the 3D models, and which one Mimic uses
mimic queue                                        # the mini being made and the ones waiting
mimic queue move raven --to front                  # or --to end, --to 3, --up, --down
mimic queue remove raven
mimic queue pause                                  # no new mini starts until: mimic queue resume
mimic --version
```

`mimic --help` lists every command and option.

A mini goes by its name in `mimic list`, or by the name you gave it in Mimic: `mimic info "Élodie"`.

| Option | What it does |
|---|---|
| `--image FILE` | Start from your own picture instead of a description |
| `--restyle` | Redraw that picture as a grey sculpt first (its tabletop export is then grey) |
| `--back FILE` / `--left FILE` / `--right FILE` | Pictures of the same character from the back and sides, besides `--image` (the front), so the 3D model doesn't guess them. Any of them; TRELLIS.2 only |
| `--improve` | Let the AI helper chosen in Settings write a fuller description first |
| `--change "TEXT"` | With `make --image` or `make-another`, redraw the picture with this change first, e.g. `"close the cape so both arms show"`. `make-another` starts from the picture it made, so changes add up. In Terminal it carries straight on; the app stops to show you the picture first |
| `--height MM` | How tall the character is, feet to top; the base adds about 2 mm |
| `--scale 28` / `32` / `35` / `54` / `75` | Match the scale your other minis use: sets the height and base for an average human (`--height` and `--base` still win) |
| `--base MM` | Size of the base: across it, or across the flat sides for a hex |
| `--base-shape round` / `square` / `hex` | The base's shape (round unless you give it; a resize keeps the mini's) |
| `--base-style plain` / `stone` / `wood` / `cobble` | A floor pressed into the top of the base: flagstones, planks or cobblestones (plain unless you give it; a resize keeps the mini's) |
| `--magnet 5x2` / `6x2` / `8x3` / `none` | A hole under the base for a round magnet this wide by this tall, in mm, with a little room to spare; the base gets taller to fit it (none unless you give it; a resize keeps the mini's) |
| `--nozzle 0.2` / `0.4` / `0.6` | Your printer's nozzle |
| `--inflate MM` | Extra thickness for thin parts (set from the nozzle unless you give it) |
| `--no-base` | Keep the character's own base instead of adding one |
| `--seed N` | Try a different version of the same character |
| `--model ID` | Make it with this 3D model instead of the one chosen in Settings (`mimic models` lists them) |
| `--new-shape` | With `make-another`, keep the picture it made and make only the 3D shape again |
| `--wait` | While another mini is being made, `make`, `resize` and `retry` join the queue and return; with this they stay until it's made |
| `--project NAME` | Put it in that project (a new one is made if needed); with `resize`, resize every mini in it |
| `--to NAME` | The new name, for `rename` and `project rename` |
| `--trash-minis` | With `project delete`, move the project's minis to the Trash too, instead of to Unsorted |
| `--object` | Make anything that isn't a character: no base, sized by its longest side, set on its flat bottom |
| `--size MM` | How big it is: for an object, its longest side (set from the nozzle unless you give it); for a character, the same as `--height` |
| `--add-base` | Give an object a base too (sized to its shadow unless you give `--base`) |
| `--json` | With `list`, `projects`, `queue`, `models` or `info`: print it as JSON, for scripts (below) |

Ctrl-C stops a mini and everything it started.

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
