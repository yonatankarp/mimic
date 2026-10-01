import Foundation
import MimicCore
import UserNotifications

/// The command-line mode: the same engine as the app, for the terminal and for scripts.
enum CLI {
    static let usage = """
    usage:
      mimic make "<name>" "<description>" [--improve] [options]
      mimic make "<name>" --image <picture> [--back <picture>] [--left <picture>] [--right <picture>] [--restyle] [options]
      mimic make-another <name> [--new-shape] [--seed N]
      mimic duplicate <name> --as "<new name>"
      mimic resize <name> [options]
      mimic import <file.glb|file.stl> [--object] [--project "<project>"] [options]
      mimic resize --project "<project>" [options]   Resize All: every mini in the project
      mimic retry <name>
      mimic open <name>              opens its print file in your slicer
      mimic info <name>              its size, filament, how it was made and its versions
      mimic rename <name> --to "<new name>"
      mimic trash <name>…            moves it to the Trash, where you can put it back
      mimic keep <name>              keeps this version and moves its other versions to the Trash
      mimic stop                     stops the mini being made, in any Mimic
      mimic list
      mimic projects
      mimic project create "<project>"
      mimic project rename "<project>" --to "<new name>"
      mimic project delete "<project>" [--trash-minis]   its minis go to Unsorted, or with it to the Trash
      mimic move <name> --project "<project>" | --unsorted
      mimic models
      mimic queue
      mimic queue remove <name>
      mimic queue move <name> --to front|end|<place> | --up | --down
      mimic queue pause | resume     no new mini starts until it's resumed, in any Mimic
      mimic --version                which Mimic this is (also -v)
      mimic --help                   this list (also -h)
    <name>: a mini's name as mimic list shows it, or as you'd type it in Mimic ("Élodie" is elodie)
    options: --height MM  --scale 28|32|35|54|75  --base MM  --nozzle 0.2|0.4|0.6  --inflate MM  --no-base  --base-shape round|square|hex  --base-style plain|stone|wood|cobble  --magnet 5x2|6x2|8x3|none  --seed N  --model ID
    anything that isn't a character: make … --object  [--size MM (longest side)]  [--add-base]
    make … --project "<project>": into that project (made if it's new); a project is a folder in the minis folder
    make … --image front.png --back b.png --left l.png --right r.png: pictures of the same character from other sides too, any of them (TRELLIS.2 only)
    make-another: the same picture or description and settings with a new seed, next to it ("<name>-2")
    make-another --new-shape: keeps the picture it made and makes only the 3D shape again, with a new seed
    duplicate: a copy with the same shape, next to it, to resize without changing the first
    import: a 3D model made elsewhere, named after its file, made print-ready (an STL is taken as millimetres, z up)
    --improve: the AI helper chosen in Settings writes a fuller description first
    --wait: while another mini is being made, make, resize and retry join the queue and return;
            --wait stays until this one is made
    """

    static func run(_ args: [String]) -> Int32 {
        if args.first == "--probe-notifications" { return probeNotifications() }
        if ["--version", "-v", "version"].contains(args.first) { print(BuildInfo.line); return 0 }
        if ["--help", "-h", "help"].contains(args.first) { print(usage); return 0 }
        // The job's own steps, each run by a job as its own program: before finding the Mimic
        // folder or stopping leftovers, since this *is* the program named in the queue's job.pid.
        if args.first == "_engine" { return engine(Array(args.dropFirst())) }
        if args.first == "_prep" { return prep(Array(args.dropFirst())) }
        // Run through a symlink (Settings shows how to put one on the PATH), the binary isn't seen as part of
        // its app, so it would read its own empty settings rather than the app's.
        let defaults = Bundle.main.bundleIdentifier == nil ? UserDefaults(suiteName: "com.mimic.app") ?? .standard : .standard
        let install = Install.locate(defaults: defaults)
        // The queue's files from before they moved out of the minis folder, as the app does.
        try? JobQueue(folder: install.queue).moveOldFiles(from: install.runs)
        let power = Power.holds(suite: defaults == .standard ? nil : "com.mimic.app")
        let timings = Timings.standard()
        var rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            JobRunner(install: install).cleanUpLeftovers()
            let waiting = Set(JobQueue(folder: install.queue).entries().map(\.name))
            let minis = Gallery.list(install.runs), projects = Gallery.projects(install.runs)
            func row(_ m: Mini, _ indent: String) {
                let state = MiniState(m, waiting: waiting).rawValue
                print("\(indent)\(m.name)\t\(state)\t\(Mini.listDate(m.created))\t\(m.displayName)")
            }
            // Without projects, the same lines as always; with them, a heading each, then Unsorted.
            guard !projects.isEmpty else { minis.forEach { row($0, "") }; return 0 }
            for p in projects + [nil] as [String?] {
                let inside = minis.filter { $0.project == p }
                if p == nil && inside.isEmpty { continue }
                print("\(p ?? "Unsorted"):")
                inside.forEach { row($0, "  ") }
                if inside.isEmpty { print("  (empty)") }
            }
            return 0
        case "projects":
            guard rest.isEmpty else { return fail(usage) }
            let minis = Gallery.list(install.runs)
            for p in Gallery.projects(install.runs) {
                let n = minis.filter { $0.project == p }.count
                print("\(p)\t\(n) mini\(n == 1 ? "" : "s")")
            }
            return 0
        case "move":
            guard rest.count >= 2, !rest[0].hasPrefix("-") else { return fail(usage) }
            let name = mini(rest[0])
            let target: String?
            switch Array(rest.dropFirst()) {
            case ["--unsorted"]: target = nil
            case let a where a.count == 2 && a[0] == "--project": 
                do { target = try project(a[1], install) } catch { return fail("\(error)") }
            default: return fail(usage)
            }
            do { try JobRunner(install: install).move(mini: name, toProject: target) } catch { return fail("\(error)") }
            print("Moved \(Mini.displayName(name, runs: install.runs)) to \(target ?? "Unsorted").")
            return 0
        case "duplicate":
            guard rest.count == 3, !rest[0].hasPrefix("-"), rest[1] == "--as" else { return fail(usage) }
            // As typed, like a name in the app: "Raven Display" is the folder raven-display.
            guard let given = Rules.typedName(rest[2]) else { return fail("Give the copy a name.") }
            let new = given.folder, of = mini(rest[0])
            do { try JobRunner(install: install).duplicate(of, as: new, shown: given.shown) }
            catch { return fail("\(error)") }
            print(JobRunner(install: install).duplicatedSaying(of, as: new))
            return 0
        case "models":
            // The app's choice, marked; downloading one is the app's job, where it shows progress.
            let selected = EngineDownload.selected(defaults: defaults)
            for m in EngineDownload.catalogue {
                let state = m.complete(in: install) ? "downloaded" : "not downloaded"
                print("\(m.id == selected.id ? "*" : " ") \(m.id)\t\(m.name)\t\(Checks.gigabytes(m.bytes)) GB\t\(state)\t\(m.described())")
            }
            print("* = the one Mimic uses. Choose or download one in the Mimic app: Settings → 3D Model.")
            return 0
        case "queue":
            let jobs = JobRunner(install: install)
            jobs.heldForPower = power
            jobs.cleanUpLeftovers()
            if rest == ["pause"] || rest == ["resume"] {
                // Started by the app, not here: this command ends at once, and a job needs its runner.
                do { try jobs.setPaused(rest == ["pause"], start: false) } catch { return fail("\(error)") }
                print(rest == ["pause"] ? "Paused the queue: a mini being made finishes, and no new one starts until you resume it (mimic queue resume, or in Mimic)."
                                        : "Resumed the queue. Mimic carries on with it, or the next time you open it.")
                return 0
            }
            if rest.first == "move" {
                let how = "usage: mimic queue move <name> --to front|end|<place> | --up | --down"
                guard rest.count >= 3 else { return fail(how) }
                let name = mini(rest[1])
                let moved: Bool
                do {
                    switch Array(rest.dropFirst(2)) {
                    case ["--up"]: moved = try jobs.move(name, by: -1)
                    case ["--down"]: moved = try jobs.move(name, by: 1)
                    case let a where a.count == 2 && a[0] == "--to":
                        guard let place = QueuePlace(a[1]) else { return fail(how) }
                        moved = try jobs.move(name, to: place)
                    default: return fail(how)
                    }
                } catch { return fail("\(error)") }
                guard moved else { return fail("\(name) isn't waiting in the queue.") }
                return listQueue(jobs, history: timings.load())
            }
            if rest.first == "remove" {
                guard rest.count == 2 else { return fail("usage: mimic queue remove <name>") }
                let name = mini(rest[1])
                do {
                    guard let said = try jobs.removeSaying(name) else { return fail("\(rest[1]) isn't waiting in the queue.") }
                    print(said)
                } catch { return fail("\(error)") }
                return 0
            }
            guard rest.isEmpty else { return fail(usage) }
            return listQueue(jobs, history: timings.load())
        case "make", "resize", "retry", "make-another", "import":
            // Resize All: `mimic resize --project <project> [options]`, every mini in it.
            let all = args[0] == "resize" && rest.first == "--project"
            guard all || rest.first.map({ !$0.hasPrefix("-") }) == true else { return fail(usage) }
            // A mini that's there goes by its name in mimic list, or as it was typed in Mimic.
            let of = all ? "" : ["make", "import"].contains(args[0]) ? rest[0] : mini(rest[0])
            // make-another makes a new mini, next to `of`; import names it after its file, `of`.
            let imported = args[0] == "import" ? ModelImport.names(for: URL(fileURLWithPath: of), in: install.runs) : nil
            // make takes a name as the app does: "Élodie" is the folder elodie, shown as typed.
            let given = args[0] == "make" ? Rules.typedName(of) : nil
            if args[0] == "make" && given == nil { return fail("Give the mini a name.") }
            var name = args[0] == "make-another" ? Gallery.nextVersionName(install.runs, of) : imported?.folder ?? given?.folder ?? of
            // Setup downloads the engine in the app, where it can show its progress. Resize and
            // import only run print prep.
            guard args[0] == "resize" || args[0] == "import" || FileManager.default.isExecutableFile(atPath: install.trellisCLI.path) else {
                return fail("Mimic needs to finish setting up. Open the Mimic app: it downloads what's missing.")
            }
            if !all { rest.removeFirst() }
            var sizes = Sizes(), image: String?, restyle = false, seed = 42, description: String?, improve = false
            var model = EngineDownload.selected(defaults: defaults)
            var object = false, addBase = false, wait = false, newShape = false, projectName: String?, seedGiven = false, shapeGiven = false, styleGiven = false, magnetGiven = false
            var scale: Int?, modelGiven = false, sides: [PictureSide: URL] = [:]
            while let a = rest.first {
                rest.removeFirst()
                func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
                switch a {
                case "--height", "--size": sizes.height = value()
                case "--scale":
                    guard let v = value().flatMap(Int.init), SizeCard.scales.contains(v) else { return fail("--scale needs \(SizeCard.scaleChoices)") }
                    scale = v
                case "--object": object = true
                case "--add-base": addBase = true
                case "--base": sizes.base = value()
                case "--nozzle": sizes.nozzle = value()
                case "--inflate": sizes.inflate = value()
                case "--no-base": sizes.noBase = true
                case "--base-shape":
                    guard let v = value().flatMap(BaseShape.init) else { return fail("--base-shape needs round, square or hex") }
                    sizes.shape = v; shapeGiven = true
                case "--base-style":
                    guard let v = value().flatMap(BaseStyle.init) else { return fail("--base-style needs plain, stone, wood or cobble") }
                    sizes.style = v; styleGiven = true
                case "--magnet":
                    let v = value()
                    guard v == "none" || v.flatMap(Magnet.init) != nil else { return fail("--magnet needs 5x2, 6x2, 8x3 or none") }
                    sizes.magnet = v.flatMap(Magnet.init); magnetGiven = true
                case "--image": image = value()
                case "--back", "--left", "--right":
                    guard let v = value() else { return fail("\(a) needs a picture") }
                    sides[PictureSide(rawValue: String(a.dropFirst(2)))!] = URL(fileURLWithPath: v)
                case "--restyle": restyle = true
                case "--improve": improve = true
                case "--wait": wait = true
                case "--new-shape": newShape = true
                case "--seed": guard let v = value().flatMap(Int.init) else { return fail("--seed needs a number") }; seed = v; seedGiven = true
                case "--project": guard let v = value() else { return fail("--project needs a project's name") }; projectName = v
                case "--model":
                    guard let v = value().flatMap(EngineDownload.model) else {
                        return fail("--model needs one of: \(EngineDownload.catalogue.map(\.id).joined(separator: ", ")) (see mimic models)")
                    }
                    model = v; modelGiven = true
                default:
                    guard description == nil, !a.hasPrefix("-") else { return fail("unknown option: \(a)\n\(usage)") }
                    description = a
                }
            }
            // Resize All starts from the first mini that can be resized, as the app's card does.
            var group: [Mini] = []
            if all {
                guard let p = projectName.flatMap({ Gallery.project(install.runs, named: $0) }) else {
                    return fail("There's no project called \(projectName ?? ""). See them all: mimic projects")
                }
                group = Gallery.list(install.runs).filter { $0.project == p }
                guard let first = group.first(where: \.hasModel) else { return fail("None of the minis in \(p) is made yet.") }
                projectName = nil
                name = first.name
            }
            // An object has no round base unless asked for one; a resize keeps what the mini is.
            if args[0] == "resize", let saved = Gallery.folder(install.runs, name).map(MiniSettings.load) {
                object = saved.isObject
                sizes = sizes.resizing(saved.made ?? saved.requested, shapeGiven: shapeGiven, styleGiven: styleGiven, magnetGiven: magnetGiven)
            }
            if projectName != nil && !["make", "import"].contains(args[0]) && !all { return fail("--project is for mimic make, import and resize --project; mimic move moves a mini") }
            if args[0] == "import" && (image != nil || restyle || improve || seedGiven || modelGiven || newShape || description != nil) {
                return fail("mimic import takes the model as it is: only size options, --object, --add-base and --project")
            }
            if newShape && args[0] != "make-another" { return fail("--new-shape is for mimic make-another") }
            if !sides.isEmpty && (args[0] != "make" || image == nil) { return fail("--back, --left and --right go with mimic make … --image <front picture>") }
            if let scale {
                if object { return fail("--scale is for characters; give an object's longest side with --size") }
                sizes = SizeCard.gameSizes(scale: scale, filling: sizes) ?? sizes
            }
            if object {
                if !addBase { sizes.noBase = true }
                // An object's base goes under its whole shadow, as in the app (SizeCard).
                else if sizes.base == nil, let h = sizes.height.flatMap(Double.init) ?? SizeCard.objectSize[sizes.nozzle ?? "0.4"] {
                    sizes.base = SizeCard.text(min(80, max(25, (h * 0.8 / 5).rounded() * 5)))
                }
                if sizes.height == nil { sizes.height = SizeCard.text(SizeCard.objectSize[sizes.nozzle ?? "0.4"] ?? 80) }
            }
            timings.seedIfNeeded(runs: install.runs)  // before the first record marks it done
            let jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
            jobs.heldForPower = power
            // This terminal runs the queue only until its own mini is made; the app runs the rest.
            jobs.keepGoing = { [name] in $0.contains { $0.name == name } }
            let mine = Mine(name: name, runs: install.runs)
            jobs.onChange = { mine.saw($0) }
            let added = Date()
            if all {
                // This terminal runs the queue until the last of them is made, and follows that one.
                let resized = Names()
                jobs.keepGoing = { $0.contains { resized.has($0.name) } }
                let done = jobs.resizeAll(group, to: sizes) { m, s in
                    try jobs.resize(name: m.name, sizes: s)
                    resized.add(m.name)
                    mine.name = m.name
                }
                if let why = done.nothingAdded(done.failure.map { "\($0)" }) { return fail(why) }
                print("\(done.added.count) \(done.added.count == 1 ? "mini" : "minis") added to the queue.\(done.sameNote)\(done.skippedNote)")
                return see(jobs, mine, wait: wait, added: added)
            }
            let ahead: Int?
            do {
                switch args[0] {
                case "make":
                    let picture: PictureSource
                    if improve && image != nil { return fail("--improve works on a description, not --image") }
                    if let image { picture = .image(URL(fileURLWithPath: image)) }
                    else if let description { picture = improve ? improved(description, defaults, kind: object ? .object : .character) : .description(description) }
                    else { return fail(usage) }
                    let into = try projectName.map { try project($0, install) }
                    ahead = try jobs.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes,
                                          kind: object ? .object : .character, model: model, project: into, shown: given?.shown,
                                          sides: sides)
                case "make-another":
                    if newShape {
                        ahead = try jobs.makeNewShape(of: of, as: name, seed: seedGiven ? seed : nil).ahead
                        print("Making \(name), a new 3D shape of \(of).")
                    } else {
                        ahead = try jobs.makeAnotherVersion(of: of, as: name, seed: seedGiven ? seed : nil).ahead
                        print("Making \(name), another version of \(of).")
                    }
                case "import":
                    let into = try projectName.map { try project($0, install) }
                    ahead = try jobs.importModel(URL(fileURLWithPath: of), name: name, shown: imported?.shown, sizes: sizes,
                                                 kind: object ? .object : .character, project: into)
                    print("Importing it as \(imported?.shown ?? name).")
                case "resize": ahead = try jobs.resize(name: name, sizes: sizes)
                default: ahead = try jobs.retry(name: name)
                }
            } catch {
                return fail("\(error)")
            }
            if ahead != nil, jobs.hold() != nil {
                print("Added to the queue.")
            } else if let ahead {
                let ready = jobs.queueTimes(jobs.queue.entries(), running: jobs.running(), history: timings.load())
                    .first { $0.entry.name == name }?.ready ?? 0
                print("Added to the queue — \(ahead) ahead of it, ready in \(JobProgress.about(ready)).")
            }
            return see(jobs, mine, wait: wait, added: added)
        case "open":
            guard rest.count == 1 else { return fail(usage) }
            guard let m = find(rest[0], install) else { return fail(notFound(rest[0])) }
            guard let stl = m.stl else { return fail("\(m.displayName) isn't made yet.") }
            // The slicer picked in the app's Settings: `defaults` are the app's, through the symlink too.
            let slicer = Slicer.preferred(defaults: defaults)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var failed: Error?
            Slicer.open(stl, in: slicer) { failed = $0; done.signal() }
            _ = done.wait(timeout: .now() + 30)
            if let failed { return fail("Couldn't open it in \(slicer?.name ?? "your slicer"): \(failed.localizedDescription)") }
            print("Opened \(m.displayName) in \(slicer?.name ?? "your Mac's app for print files").")
            return 0
        case "info":
            guard rest.count == 1 else { return fail(usage) }
            let minis = Gallery.list(install.runs)
            guard let m = minis.first(where: { $0.name == mini(rest[0]) }) else { return fail(notFound(rest[0])) }
            let waiting = Set(JobQueue(folder: install.queue).entries().map(\.name))
            MiniInfo(m, in: minis, waiting: waiting).lines.forEach { print($0) }
            return 0
        case "rename":
            guard rest.count == 3, !rest[0].hasPrefix("-"), rest[1] == "--to" else { return fail(usage) }
            let old = mini(rest[0]), before = Mini.displayName(old, runs: install.runs)
            do {
                let new = try JobRunner(install: install).rename(old, typed: rest[2])
                print("Renamed \(before) to \(Mini.displayName(new, runs: install.runs)) (\(new)).")
            } catch { return fail("\(error)") }
            return 0
        case "trash":
            guard !rest.isEmpty, !rest.contains(where: { $0.hasPrefix("-") }) else { return fail(usage) }
            let jobs = JobRunner(install: install)
            var code: Int32 = 0
            for text in rest {
                guard let m = find(text, install) else { code = fail(notFound(text)); continue }
                do { try jobs.moveToTrash(m); print("Moved \(m.displayName) to the Trash.") } catch { code = fail("\(error)") }
            }
            return code
        case "keep":
            guard rest.count == 1, !rest[0].hasPrefix("-") else { return fail(usage) }
            let jobs = JobRunner(install: install)
            let minis = Gallery.list(install.runs)
            guard let m = minis.first(where: { $0.name == mini(rest[0]) }) else { return fail(notFound(rest[0])) }
            let picked = Gallery.toKeep(m, in: minis, busyWith: jobs.running()?.name)
            guard !picked.trash.isEmpty || picked.staying != nil else { print("\(m.displayName) has no other versions."); return 0 }
            var code: Int32 = 0
            for v in picked.trash {
                do { try jobs.moveToTrash(v); print("Moved \(v.displayName) to the Trash.") } catch { code = fail("\(error)") }
            }
            if let s = picked.staying { code = fail("\(s.displayName) is being made, so it wasn't moved to the Trash. Move it there once it's done.") }
            // As the app offers after Keep This One: the plain name, now that it's free.
            let root = m.settings.versionOf ?? m.name
            if code == 0, root != m.name, !Gallery.nameInUse(install.runs, root) {
                let plain = Rules.shownName(carrying: m.displayName, to: root) ?? root
                print("Its plain name is free now: mimic rename \(m.name) --to \"\(plain)\"")
            }
            return code
        case "stop":
            guard rest.isEmpty else { return fail(usage) }
            let jobs = JobRunner(install: install)
            jobs.cleanUpLeftovers()
            switch jobs.stopElsewhere() {
            case .nothing:
                print("Nothing is being made.")
            case .stopped(let s):
                let who = Mini.displayName(s.name, runs: install.runs)
                print(s.kind == .prep ? "Stopped resizing \(who). It keeps its previous size."
                                      : "Stopped making \(who). Nothing was kept. It's in the Trash if you want the pieces.")
            case .noAnswer(let s):
                return fail("\(Mini.displayName(s.name, runs: install.runs)) didn't stop. Stop it where it's being made: in Mimic, or with Ctrl-C in the Terminal window making it.")
            }
            return 0
        case "project":
            let jobs = JobRunner(install: install)
            func existing(_ text: String) throws -> String {
                guard let p = Gallery.project(install.runs, named: text) else { throw Refusal("There's no project called \(text). See them all: mimic projects") }
                return p
            }
            do {
                switch rest.first {
                case "create" where rest.count == 2:
                    print("Made a new project, \(try Gallery.createProject(install.runs, rest[1])).")
                case "rename" where rest.count == 4 && rest[2] == "--to":
                    let old = try existing(rest[1])
                    print("Renamed the project \(old) to \(try jobs.renameProject(old, to: rest[3])).")
                case "delete" where rest.count == 2 || (rest.count == 3 && rest[2] == "--trash-minis"):
                    let p = try existing(rest[1]), keep = rest.count == 2
                    try jobs.deleteProject(p, keepMinis: keep)
                    print(keep ? "Deleted the project \(p): its minis are in Unsorted now, and its folder is in the Trash."
                               : "Deleted the project \(p): it's in the Trash with its minis.")
                default:
                    return fail(usage)
                }
            } catch { return fail("\(error)") }
            return 0
        default:
            return fail(usage)
        }
    }

    /// A mini named on the command line: its folder's name, as `mimic list` shows it, or its name
    /// as typed in Mimic ("Élodie" is elodie).
    private static func mini(_ text: String) -> String { Rules.isValidName(text) ? text : Rules.folderName(text) }

    private static func find(_ text: String, _ install: Install) -> Mini? {
        let name = mini(text)
        return Gallery.list(install.runs).first { $0.name == name }
    }

    private static func notFound(_ text: String) -> String { "There's no mini called \(text). See them all: mimic list" }

    /// A refusal of the command line's own, in words.
    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Names added on one thread and read on the runner's.
    final class Names: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func add(_ name: String) { lock.withLock { _ = names.insert(name) } }
        func has(_ name: String) -> Bool { lock.withLock { names.contains(name) } }
    }

    /// After a job is asked for: runs it here and follows it when this terminal took the queue,
    /// else says why it waits, and with `--wait` waits for it.
    private static func see(_ jobs: JobRunner, _ mine: Mine, wait: Bool, added: Date) -> Int32 {
        // Running here (this one, or one that was waiting before it): see it through.
        if jobs.status?.running == true { return follow(jobs, mine) }
        switch jobs.hold() {
        case .paused?: print("The queue is paused, so it waits until you resume it: mimic queue resume, or in Mimic.")
        case .battery?: print(QueueHold.battery.sentence)
        case nil: break
        }
        guard wait else {
            if jobs.hold() != nil { return 0 }
            print("It starts when the one before it is done, in whichever Mimic is making that. If none is open by then, it starts the next time you open Mimic. See the queue: mimic queue")
            return 0
        }
        return watch(jobs, mine, added: added)
    }

    /// The project named on the command line, as it's spelled on disk ("tiefling party" finds
    /// "Tiefling Party"); a new one is made.
    private static func project(_ text: String, _ install: Install) throws -> String {
        if let p = Gallery.project(install.runs, named: text) { return p }
        let p = try Gallery.createProject(install.runs, text)
        print("Made a new project, \(p).")
        return p
    }

    /// The helper's description, or the original with a quiet note when it can't help: a failed
    /// helper never stops a mini.
    private static func improved(_ description: String, _ defaults: UserDefaults, kind: MiniKind) -> PictureSource {
        guard let helper = DescriptionHelper.configured(defaults: defaults) else {
            print("No AI helper is set up (Mimic → Settings). Using your description as it is.")
            return .description(description)
        }
        print("Improving the description…")
        do {
            let better = try helper.improve(description, kind: kind.rawValue)
            print("✨ Improved description: \(better)")
            return .description(better, original: description)
        } catch {
            print("Couldn't improve it: \(error) Using your description as it is.")
            return .description(description)
        }
    }

    /// The latest status of this command's own mini, as the runner reports it.
    final class Mine: @unchecked Sendable {
        let runs: URL
        private let lock = NSLock()
        private var mine: String
        private var last: JobStatus?
        private var shown: (String, Int)?
        private var openingSaid = false
        init(name: String, runs: URL) { mine = name; self.runs = runs }
        /// Resize All follows the last mini it added, so it changes as they're added.
        var name: String {
            get { lock.withLock { mine } }
            set { lock.withLock { mine = newValue } }
        }
        var status: JobStatus? { lock.withLock { last } }

        /// Prints each step as it starts, naming the mini when it isn't this one.
        func saw(_ s: JobStatus) {
            let line: String? = lock.withLock {
                if s.name == mine { last = s }
                guard s.running, shown.map({ $0 != (s.name, s.step) }) ?? true else { return nil }
                shown = (s.name, s.step)
                let who = s.name == mine ? "" : "\(Mini.displayName(s.name, runs: runs)) (waiting before yours): "
                return "[\(s.step)/3] \(who)\(JobRunner.label(s.step))"
            }
            if let line { print(line) }
            if s.openingDrawThings, lock.withLock({ () -> Bool in defer { openingSaid = true }; return !openingSaid }) {
                print("Opening Draw Things…")
            }
        }
    }

    /// Runs this terminal's jobs to the end of its own mini; Ctrl-C stops the running job and
    /// everything it started, and leaves the queue to the app.
    private static func follow(_ jobs: JobRunner, _ mine: Mine) -> Int32 {
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
        interrupt.setEventHandler { print("\nStopping…"); jobs.keepGoing = { _ in false }; jobs.cancel() }
        interrupt.resume()
        if let s = jobs.status { mine.saw(s) }
        jobs.waitUntilDone()
        guard let s = mine.status ?? jobs.status.flatMap({ $0.name == mine.name ? $0 : nil }) else {
            // Stopped (Ctrl-C) before its turn came: it's still waiting.
            print("Stopped. \(Mini.displayName(mine.name, runs: mine.runs)) is still in the queue (mimic queue remove \(mine.name) takes it out).")
            return 130
        }
        let folder = Gallery.folder(jobs.install.runs, s.name) ?? jobs.install.runs.appendingPathComponent(s.name)
        if s.canceled { print("Stopped."); return 130 }
        if s.succeeded {
            print("Done: \(folder.appendingPathComponent("\(s.name).stl").path)")
            for note in s.notes { print("Heads up: \(note)") }
            if s.fragile { print("Heads up: some thin parts may be fragile. Check it in your slicer before printing.") }
            return 0
        }
        return fail("It didn't finish: \(s.problem ?? "a step failed (exit \(s.exit ?? -1))"). See the logs in \(folder.path)")
    }

    /// `--wait` while another Mimic runs the queue: shows its progress until it's made there, or
    /// runs it here if that Mimic goes away first. Ctrl-C leaves it in the queue.
    private static func watch(_ jobs: JobRunner, _ mine: Mine, added: Date) -> Int32 {
        print("Waiting for it. Ctrl-C stops waiting; it stays in the queue.")
        var seen = false
        var idleSince: Date?
        while true {
            let running = jobs.running()
            let queue = jobs.queue.entries()
            let waiting = queue.contains { $0.name == mine.name }
            idleSince = running == nil ? idleSince ?? Date() : nil
            // Its own turn, or nobody has picked the queue up for a while (no Mimic open): run
            // here. Otherwise the app runs the jobs ahead of it, where they can be stopped.
            if waiting, queue.first?.name == mine.name || idleSince.map({ Date().timeIntervalSince($0) > 10 }) == true {
                jobs.pump()
                if jobs.status?.running == true { return follow(jobs, mine) }
            }
            if let r = running, r.name == mine.name { seen = true; mine.saw(r) }
            if !waiting && running?.name != mine.name {
                // Made (or not) by another Mimic: its folder says which.
                guard let folder = Gallery.folder(jobs.install.runs, mine.name) else { print("Stopped, or taken out of the queue."); return 130 }
                let stl = folder.appendingPathComponent("\(mine.name).stl")
                let at = (try? FileManager.default.attributesOfItem(atPath: stl.path))?[.modificationDate] as? Date
                if let at, at >= added { print("Done: \(stl.path)"); return 0 }
                return fail(seen ? "It didn't finish. See the logs in \(folder.path)" : "It was taken out of the queue.")
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// `mimic queue`: what's running and what's waiting, with times.
    private static func listQueue(_ jobs: JobRunner, history: [TimingRecord]) -> Int32 {
        let running = jobs.running(), queue = jobs.queue.entries()
        if let r = running {
            let left = jobs.estimate(r.name, r.kind, history: history).left(r)
            let importing = Gallery.folder(jobs.install.runs, r.name).map(JobRunner.importing) ?? false
            print("Now: \(JobRunner.doing(r.kind, importing: importing).lowercased()) \(r.name), step \(r.step) of 3, \(JobProgress.about(left)) left")
        } else {
            print(queue.isEmpty ? "Nothing is being made." : jobs.hold() != nil ? "Nothing is being made right now."
                  : "Nothing is being made right now: the queue starts when you open Mimic.")
        }
        if let hold = jobs.hold() { print(hold.sentence) }
        for (i, row) in jobs.queueTimes(queue, running: running, history: history).enumerated() {
            print("\(i + 1). \(row.entry.name)\t\(row.entry.job == .prep ? "resize" : "make")\ttakes \(JobProgress.about(row.estimate.total))\tready in \(JobProgress.about(row.ready))")
        }
        return 0
    }

    /// Step 2 of a job, run by the job itself (not for people, so not in the usage):
    /// `mimic _engine <source.png> <model.glb> --seed N --engine <dir> [--model ID] [--back|--left|--right <picture>]…`.
    private static func engine(_ args: [String]) -> Int32 {
        var rest = args, seed = 42, engine: String?, files: [String] = [], model = EngineDownload.standard
        var sides: [(PictureSide, URL)] = []
        while let a = rest.first {
            rest.removeFirst()
            if a.hasPrefix("--"), let side = PictureSide(rawValue: String(a.dropFirst(2))) {
                guard let v = rest.first else { return fail("\(a) needs a picture") }
                sides.append((side, URL(fileURLWithPath: v))); rest.removeFirst()
                continue
            }
            switch a {
            case "--seed": guard let v = rest.first.flatMap(Int.init) else { return fail("--seed needs a number") }; seed = v; rest.removeFirst()
            case "--engine": guard let v = rest.first else { return fail("--engine needs a folder") }; engine = v; rest.removeFirst()
            case "--model":
                guard let v = rest.first.flatMap(EngineDownload.model) else { return fail("--model needs a known model id") }
                model = v; rest.removeFirst()
            default: files.append(a)
            }
        }
        guard files.count == 2, let engine else { return fail("usage: mimic _engine <source.png> <model.glb> --seed N --engine <dir>") }
        let out = FileHandle.standardOutput
        do {
            try Engine.make(source: URL(fileURLWithPath: files[0]), output: URL(fileURLWithPath: files[1]), seed: seed,
                            engine: URL(fileURLWithPath: engine), model: model, sides: sides, environment: ProcessInfo.processInfo.environment) {
                out.write(Data(($0 + "\n").utf8))
            }
            return 0
        } catch {
            _ = fail("\(error)")
            return 1
        }
    }

    /// Step 3 of a job, run by the job itself: `mimic _prep <model.glb> <name.stl> [flags]`.
    private static func prep(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)  // prep.log shows each step as it happens
        do {
            let options = try PrepOptions.parse(args)
            let result = try Prep.run(options) { print($0) }
            result.lines.forEach { print($0) }
            try Render.views(result.mesh, besides: URL(fileURLWithPath: options.stl))
            return 0
        } catch {
            return fail(Prep.failure + "\(error)")
        }
    }

    private static func probeNotifications() -> Int32 {
        // Feasibility check: does the notification system accept this self-assembled app?
        // Reading the settings needs a valid bundle but, unlike asking, shows no prompt.
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status = "unknown"
        UNUserNotificationCenter.current().getNotificationSettings { s in
            status = String(describing: s.authorizationStatus.rawValue)
            done.signal()
        }
        done.wait()
        print("notifications reachable, authorization status \(status) (0 = not yet asked)")
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
}
