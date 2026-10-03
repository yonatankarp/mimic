# Mimic from a terminal

Everything Mimic does in its window, it also does as a `mimic` command in Terminal, with the same
engine and the same minis. It's handy for making a batch of minis from a script, resizing a whole
project in one go, or reading your minis as JSON.

Each section below shows the commands for one job, then every option those commands take. A
command refuses an option it doesn't take, rather than ignoring it.

## Install it

1. Finish Mimic's first-launch download in the app: `make` and `retry` need the 3D engine.
2. Choose **Mimic → Install Command-Line Tool…**, copy the command it shows, and paste it into
   Terminal. It asks for your Mac password once.
3. Check it works:

```bash
mimic --version
```

`mimic --help` lists every command and option.

## Make a mini

Give it a name and a description, or a picture:

```bash
mimic make "Dwarf Cleric" "dwarf cleric, warhammer held against chest"
mimic make tiefling --image art.png --restyle --height 38 --nozzle 0.2
mimic make teapot "a round teapot with a curved spout" --object --size 80
```

The name can be anything, as in the app. Terminal shows each step while the mini is made and says
where its print file is when it's done. Ctrl-C stops the mini and everything it started.

If Mimic is already making another mini, in the app or another Terminal, yours joins the
[queue](queue.md) and the command returns straight away. Add `--wait` to stay and watch it instead.

A picture drawn from a description, or redrawn with `--restyle` or `--change`, is made where the
app's **Settings → Draw Things & AI** says: Draw Things on your Mac, or Black Forest Labs or
OpenAI online with the key saved there (see
[Choose what makes the pictures](settings.md#choose-what-makes-the-pictures)).

| Option | What it does |
|---|---|
| `--image FILE` | Start from your own picture instead of a description |
| `--restyle` | Redraw that picture as a grey sculpt first, like **Turn it into a grey sculpt first** in New Mini (its tabletop export is then grey) |
| `--back FILE` / `--left FILE` / `--right FILE` | With `--image` (the front): pictures of the same character from the back and sides, so the 3D model doesn't guess them. Any of them; TRELLIS.2 only |
| `--change "TEXT"` | With `--image`: redraw the picture with this change first, e.g. `"close the cape so both arms show"`. It gets the grey sculpt too |
| `--improve` | With a description: let the AI helper chosen in Settings write a fuller one first |
| `--object` | Make anything that isn't a character: no base, sized by its longest side, set on its flat bottom |
| `--seed N` | Try a different version of the same character (42 unless you give it) |
| `--model ID` | Make it with this 3D model instead of the one chosen in Settings (`mimic models` lists them) |
| `--project NAME` | Put it in that project; a new one is made if needed |
| `--wait` | If another mini is being made, stay until this one is made, instead of returning once it's in the queue |

Its size, base and nozzle, the same choices as [Sizes and bases](sizes-and-bases.md):

--8<-- "docs/.snippets/size-options.md"

## Resize a mini, or a whole project

```bash
mimic resize tiefling --height 32 --base 25
mimic resize --project "Tiefling Party" --height 32
```

Only print prep runs again, so a resize takes about a minute. With `--project`, every mini in the
project gets the new size, like **Resize All…**. A resize keeps the mini's base shape, floor, magnet
and nozzle unless you give them.

| `resize` option | What it does |
|---|---|
| `--project NAME` | Resize every mini in that project, instead of one mini |
| `--wait` | If another mini is being made, stay until this one is resized |

Plus the size, base and nozzle to resize it to:

--8<-- "docs/.snippets/size-options.md"

## Make another version

```bash
mimic retry tiefling                    # carry on from the step that failed
mimic make-another tiefling             # the same, with a new seed: "tiefling-2"
mimic make-another tiefling --new-shape # keep its picture, make only the 3D shape again
mimic make-another tiefling --change "close the cape so both arms show"
mimic keep tiefling-2                   # keep this one, move the other versions to the Trash
```

These match [Versions](versions.md) in the app. `make-another` uses the mini's own picture or
description and sizes. `retry` takes only `--wait`; `keep` takes no options.

| `make-another` option | What it does |
|---|---|
| `--new-shape` | Keep the picture it made and make only the 3D shape again |
| `--change "TEXT"` | Redraw the picture with this change first. It starts from the picture this mini was made from, so changes add up. In Terminal it carries straight on; the app stops to show you the picture first |
| `--seed N` | Use this seed instead of a new one |
| `--wait` | If another mini is being made, stay until this one is made |

## Copy and import

```bash
mimic duplicate tiefling --as "Tiefling Display"   # the same shape, to resize separately
mimic import "Ogre Chief.stl" --height 32          # print prep for a GLB or STL made elsewhere
```

`duplicate` needs `--as "<new name>"`, the copy's name, and takes nothing else. `import` takes the
model as it is, so it has no picture options:

| `import` option | What it does |
|---|---|
| `--object` | It isn't a character: no base, sized by its longest side |
| `--project NAME` | Put it in that project; a new one is made if needed |
| `--wait` | If another mini is being made, stay until this one is made |

Plus its size, base and nozzle:

--8<-- "docs/.snippets/size-options.md"

## Open and export

```bash
mimic open tiefling           # open its print file in your slicer
mimic export tiefling --vtt   # a low-poly .glb for a virtual tabletop
```

`open` uses the slicer chosen in Settings and takes no options. `export` saves `<name>.glb` (the
name `mimic list` shows) in the folder you're in, replacing a file of that name already there; see
[Printing and exporting](printing.md) for when it comes out in colour. If it should have been in
colour but comes out grey, it says why.

| `export` option | What it does |
|---|---|
| `--vtt` | The kind of export, for a virtual tabletop (needed) |
| `--triangles N` | How many triangles the low-poly model has (5,000 unless you give it) |

## Find, rename and organise your minis

```bash
mimic list                                  # every mini, by project
mimic info tiefling                         # its size, filament, how it was made and its versions
mimic rename tiefling --to "Tiefling Warlock"
mimic trash tiefling-3                      # to the Trash, where you can put it back
mimic projects
mimic project create "Orc Warband"
mimic project rename "Orc Warband" --to "Orc Horde"
mimic move tiefling --project "Orc Horde"   # or --unsorted
mimic project delete "Orc Horde"            # its minis go to Unsorted
```

A mini goes by its name in `mimic list`, or by the name you gave it in Mimic:
`mimic info "Élodie"`. Changes show in the app straight away. See
[Your minis and projects](organizing.md).

| Option | Commands | What it does |
|---|---|---|
| `--json` | `list`, `info`, `projects` | Print it as JSON, for scripts ([below](#json-for-scripts)) |
| `--to NAME` | `rename`, `project rename` | The new name (needed) |
| `--project NAME` / `--unsorted` | `move` | Where to move it (one of them is needed) |
| `--trash-minis` | `project delete` | Move the project's minis to the Trash too, instead of to Unsorted |

`trash` takes one or more names and no options; `project create` takes only the project's name.

## Watch and change the queue

```bash
mimic queue                         # the mini being made and the ones waiting
mimic queue move raven --to front   # or --to end, --to 3, --up, --down
mimic queue remove raven
mimic queue pause                   # no new mini starts until: mimic queue resume
mimic stop                          # stop the mini being made, in Mimic or another Terminal
```

There's one queue for the app and every Terminal. See [The queue](queue.md).

| Option | Commands | What it does |
|---|---|---|
| `--json` | `queue` | Print it as JSON, for scripts ([below](#json-for-scripts)) |
| `--to front` / `end` / `<place>` | `queue move` | Where to move it: first, last, or a place from 1 |
| `--up` / `--down` | `queue move` | One place up or down |

`queue remove`, `queue pause`, `queue resume` and `stop` take no options.

## See the 3D models

```bash
mimic models   # the 3D models, which are downloaded, and which one Mimic uses
```

`--json` prints it as JSON. Change the model in **Settings → 3D Model**, or for one mini with
`make --model`.

## Exit codes

For scripts, `mimic` says how it went in its exit code, and why on stderr:

| Code | Means |
|---|---|
| 0 | It worked: done, or added to the queue |
| 1 | It didn't work: a mini that isn't there, a mini that didn't finish, or Mimic not set up yet |
| 64 | Typed wrong: a command or option that isn't there, an option the command doesn't take, an option without its value, or a value it can't take |
| 130 | Stopped with Ctrl-C, or taken out of the queue while `--wait` waited for it |

## JSON for scripts

`mimic list --json`, `projects --json`, `queue --json`, `models --json` and `info <name> --json` print JSON. These
field names stay as they are: new ones may be added, but none is renamed or removed. Dates are
ISO 8601 (`2026-09-21T14:13:20Z`), sizes are millimetres and times are seconds. A field with no
value is left out, and so is a size that isn't a number (one edited by hand to `inf`, say).

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
  `seed`, `shapeSeed`, `model` (left out for one you imported), `greySculpt`, `cartoon`, `fixes`: the changes asked for in its picture
  with `--change` or in the app, as typed, oldest first), `versions` (names, itself included) and
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
