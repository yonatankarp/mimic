import Foundation

/// `mimic --help`: every command and option. Here rather than with the command line itself, so
/// the completion scripts (`Completions`) are made from it and a test can hold them to it.
public enum Usage {
    public static let text = """
    usage:
      mimic make "<name>" "<description>" [--improve] [options]
      mimic make "<name>" --image <picture> [--restyle] [options]
      mimic make-another <name> [--new-shape] [--seed N]
      mimic duplicate <name> --as "<new name>"
      mimic resize <name> [options]
      mimic import <file.glb|file.stl> [--object] [--project "<project>"] [options]
      mimic resize --project "<project>" [options]   Resize All: every mini in the project
      mimic retry <name>
      mimic open <name>              opens its print file in your slicer
      mimic info <name> [--json]     its size, filament, how it was made and its versions
      mimic rename <name> --to "<new name>"
      mimic trash <name>…            moves it to the Trash, where you can put it back
      mimic keep <name>              keeps this version and moves its other versions to the Trash
      mimic stop                     stops the mini being made, in any Mimic
      mimic list [--json]
      mimic projects [--json]
      mimic project create "<project>"
      mimic project rename "<project>" --to "<new name>"
      mimic project delete "<project>" [--trash-minis]   its minis go to Unsorted, or with it to the Trash
      mimic move <name> --project "<project>" | --unsorted
      mimic models [--json]
      mimic queue [--json]
      mimic queue remove <name>
      mimic queue move <name> --to front|end|<place> | --up | --down
      mimic queue pause | resume     no new mini starts until it's resumed, in any Mimic
      mimic completions zsh|bash|fish   prints the completion script for your shell (the README says how to add it)
      mimic --version                which Mimic this is (also -v)
      mimic --help                   this list (also -h)
    --json: list, projects, queue, models and info as JSON for scripts (the README describes it)
    <name>: a mini's name as mimic list shows it, or as you'd type it in Mimic ("Élodie" is elodie)
    options: --height MM  --scale 28|32|35|54|75  --base MM  --nozzle 0.2|0.4|0.6  --inflate MM  --no-base  --base-shape round|square|hex  --base-style plain|stone|wood|cobble  --magnet 5x2|6x2|8x3|none  --seed N  --model ID
    anything that isn't a character: make … --object  [--size MM (longest side)]  [--add-base]
    make … --project "<project>": into that project (made if it's new); a project is a folder in the minis folder
    make-another: the same picture or description and settings with a new seed, next to it ("<name>-2")
    make-another --new-shape: keeps the picture it made and makes only the 3D shape again, with a new seed
    duplicate: a copy with the same shape, next to it, to resize without changing the first
    import: a 3D model made elsewhere, named after its file, made print-ready (an STL is taken as millimetres, z up)
    --improve: the AI helper chosen in Settings writes a fuller description first
    --wait: while another mini is being made, make, resize and retry join the queue and return;
            --wait stays until this one is made
    """
}
