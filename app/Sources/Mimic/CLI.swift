import Foundation
import MimicCore

/// The command-line mode: the same engine as the app, for the terminal and for scripts.
enum CLI {
    static var usage: String { Usage.text }

    static func run(_ args: [String]) -> Int32 {
        if ["--version", "-v", "version"].contains(args.first) { print(BuildInfo.line); return 0 }
        if ["--help", "-h", "help"].contains(args.first) { print(usage); return 0 }
        // The job's own steps, each run by a job as its own program: before finding the Mimic
        // folder or stopping leftovers, since this *is* the program named in the queue's job.pid.
        if args.first == "_engine" { return engine(Array(args.dropFirst())) }
        if args.first == "_prep" { return prep(Array(args.dropFirst())) }
        if args.first == "completions" {
            guard args.count == 2, let shell = Completions.Shell(rawValue: args[1]) else { return fail("usage: mimic completions zsh|bash|fish") }
            print(Completions.script(shell), terminator: "")
            return 0
        }
        // Run through a symlink (Settings shows how to put one on the PATH), the binary isn't seen as part of
        // its app, so it would read its own empty settings rather than the app's.
        let defaults = Bundle.main.bundleIdentifier == nil ? UserDefaults(suiteName: "com.mimic.app") ?? .standard : .standard
        let install = Install.locate(defaults: defaults)
        let cli = Context(defaults: defaults, install: install, power: Power.holds(suite: defaults == .standard ? nil : "com.mimic.app"),
                          timings: Timings.standard())
        var rest = Array(args.dropFirst())
        // --json on a listing (#130): taken out first, so each listing reads its arguments as before.
        let json = ["list", "projects", "queue", "models", "info"].contains(args.first) && rest.contains("--json")
        rest.removeAll { $0 == "--json" && json }
        switch args.first {
        case "_names": return names(rest, cli)
        case "list": return list(cli, json: json)
        case "projects": return projects(rest, cli, json: json)
        case "move": return move(rest, cli)
        case "duplicate": return duplicate(rest, cli)
        case "models": return models(cli, json: json)
        case "queue": return queue(rest, cli, json: json)
        case "make", "resize", "retry", "make-another", "import": return make(args, cli)
        case "open": return open(rest, cli)
        case "export": return export(rest, cli)
        case "info": return info(rest, cli, json: json)
        case "rename": return rename(rest, cli)
        case "trash": return trash(rest, cli)
        case "keep": return keep(rest, cli)
        case "stop": return stop(rest, cli)
        case "project": return manageProject(rest, cli)
        default: return fail(usage)
        }
    }

    /// What every command finds out first: the app's settings and the minis folder.
    private struct Context {
        let defaults: UserDefaults
        let install: Install
        let power: @Sendable () -> Bool
        let timings: Timings
    }

    /// For the completion scripts (not for people, so not in the usage): a name a line.
    private static func names(_ rest: [String], _ cli: Context) -> Int32 {
        switch rest {
        case ["minis"]: Gallery.list(cli.install.runs).forEach { print($0.name) }
        case ["projects"]: Gallery.projects(cli.install.runs).forEach { print($0) }
        default: return fail("usage: mimic _names minis|projects")
        }
        return 0
    }

    private static func list(_ cli: Context, json: Bool) -> Int32 {
        let install = cli.install
        JobRunner(install: install).cleanUpLeftovers()
        let waiting = Set(JobQueue(folder: install.queue).entries().map(\.name))
        let minis = Gallery.list(install.runs), projects = Gallery.projects(install.runs)
        if json { return printJSON(minis.map { ListingJSON.MiniRow($0, waiting: waiting) }) }
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
    }

    private static func projects(_ rest: [String], _ cli: Context, json: Bool) -> Int32 {
        guard rest.isEmpty else { return fail(usage) }
        let install = cli.install
        let minis = Gallery.list(install.runs)
        if json { return printJSON(Gallery.projects(install.runs).map { ListingJSON.Project($0, minis: minis) }) }
        for p in Gallery.projects(install.runs) {
            let n = minis.filter { $0.project == p }.count
            print("\(p)\t\(n) mini\(n == 1 ? "" : "s")")
        }
        return 0
    }

    private static func move(_ rest: [String], _ cli: Context) -> Int32 {
        let install = cli.install
        guard rest.count >= 2, !rest[0].hasPrefix("-") else { return fail(usage) }
        let name = Rules.miniName(rest[0])
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
    }

    private static func duplicate(_ rest: [String], _ cli: Context) -> Int32 {
        let install = cli.install
        guard rest.count == 3, !rest[0].hasPrefix("-"), rest[1] == "--as" else { return fail(usage) }
        // As typed, like a name in the app: "Raven Display" is the folder raven-display.
        guard let given = Rules.typedName(rest[2]) else { return fail("Give the copy a name.") }
        let new = given.folder, of = Rules.miniName(rest[0])
        do { try JobRunner(install: install).duplicate(of, as: new, shown: given.shown) }
        catch { return fail("\(error)") }
        print(JobRunner(install: install).duplicatedSaying(of, as: new))
        return 0
    }

    /// The app's choice, marked; downloading one is the app's job, where it shows progress.
    private static func models(_ cli: Context, json: Bool) -> Int32 {
        let install = cli.install
        let selected = EngineDownload.selected(defaults: cli.defaults)
        if json {
            return printJSON(EngineDownload.catalogue.map { ListingJSON.Model($0, downloaded: $0.complete(in: install), selected: $0.id == selected.id) })
        }
        for m in EngineDownload.catalogue {
            let state = m.complete(in: install) ? "downloaded" : "not downloaded"
            print("\(m.id == selected.id ? "*" : " ") \(m.id)\t\(m.name)\t\(Checks.gigabytes(m.bytes)) GB\t\(state)\t\(m.described())")
        }
        print("* = the one Mimic uses. Choose or download one in the Mimic app: Settings → 3D Model.")
        return 0
    }

    private static func queue(_ rest: [String], _ cli: Context, json: Bool) -> Int32 {
        let jobs = JobRunner(install: cli.install)
        jobs.heldForPower = cli.power
        jobs.cleanUpLeftovers()
        let command: QueueCommand
        do { command = try QueueCommand.parse(rest) } catch { return fail("\(error)") }
        switch command {
        case .pause, .resume:
            // Started by the app, not here: this command ends at once, and a job needs its runner.
            do { try jobs.setPaused(command == .pause, start: false) } catch { return fail("\(error)") }
            print(command == .pause ? "Paused the queue: a mini being made finishes, and no new one starts until you resume it (mimic queue resume, or in Mimic)."
                                    : "Resumed the queue. Mimic carries on with it, or the next time you open it.")
            return 0
        case .move(let name, let how):
            let moved: Bool
            do {
                switch how {
                case .by(let step): moved = try jobs.move(name, by: step)
                case .to(let place): moved = try jobs.move(name, to: place)
                }
            } catch { return fail("\(error)") }
            guard moved else { return fail("\(name) isn't waiting in the queue.") }
            return listQueue(jobs, history: cli.timings.load())
        case .remove(let name, let typed):
            do {
                guard let said = try jobs.removeSaying(name) else { return fail("\(typed) isn't waiting in the queue.") }
                print(said)
            } catch { return fail("\(error)") }
            return 0
        case .list:
            return listQueue(jobs, history: cli.timings.load(), json: json)
        }
    }

    /// `mimic make`, `resize`, `retry`, `make-another` and `import`; `args` from the command's name on.
    private static func make(_ args: [String], _ cli: Context) -> Int32 {
        let install = cli.install, timings = cli.timings
        let request: MakeRequest
        do { request = try MakeRequest.parse(args, engineReady: FileManager.default.isExecutableFile(atPath: install.trellisCLI.path)) }
        catch { return fail("\(error)") }
        let of = request.of
        // make-another makes a new mini, next to `of`; import names it after its file, `of`.
        let imported = request.command == .import ? ModelImport.names(for: URL(fileURLWithPath: of), in: install.runs) : nil
        var name = request.command == .makeAnother ? Gallery.nextVersionName(install.runs, of) : imported?.folder ?? of
        var sizes = request.sizes, object = request.object
        // Resize All starts from the first mini that can be resized, as the app's card does.
        var group: [Mini] = []
        var all = false
        if case .resizeAll(let project) = request.command {
            guard let p = Gallery.project(install.runs, named: project) else {
                return fail("There's no project called \(project). See them all: mimic projects")
            }
            group = Gallery.list(install.runs).filter { $0.project == p }
            guard let first = group.first(where: \.hasModel) else { return fail("None of the minis in \(p) is made yet.") }
            all = true
            name = first.name
        }
        // An object has no round base unless asked for one; a resize keeps what the mini is.
        if request.command == .resize || all, let saved = Gallery.folder(install.runs, name).map(MiniSettings.load) {
            object = saved.isObject
            sizes = sizes.resizing(saved.made ?? saved.requested, shapeGiven: request.shapeGiven, styleGiven: request.styleGiven,
                                   magnetGiven: request.magnetGiven)
        }
        do { sizes = try request.checkedSizes(sizes, object: object) } catch { return fail("\(error)") }
        timings.seedIfNeeded(runs: install.runs)  // before the first record marks it done
        let jobs = JobRunner(install: install, timings: timings, version: BuildInfo.version)
        jobs.heldForPower = cli.power
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
            print("\(JobPresentation.QueuedNote.added(done.added.count))\(done.sameNote)\(done.skippedNote)")
            return see(jobs, mine, wait: request.wait, added: added)
        }
        let kind: MiniKind = object ? .object : .character
        let ahead: Int?
        do {
            switch request.command {
            case .make:
                let picture: PictureSource
                if let image = request.image { picture = .image(URL(fileURLWithPath: image)) }
                else if let description = request.description {
                    picture = request.improve ? improved(description, cli.defaults, kind: kind) : .description(description)
                }
                else { return fail(usage) }
                let into = try request.project.map { try project($0, install) }
                if request.change != nil && !request.restyle { print("A change redraws the picture, so it gets the grey sculpt too.") }
                let used = request.change.flatMap { worded($0, cli.defaults, kind: kind) }
                ahead = try jobs.make(name: name, picture: picture, restyle: request.restyle, seed: request.seed ?? 42, sizes: sizes,
                                      kind: kind, model: request.model ?? EngineDownload.selected(defaults: cli.defaults), project: into,
                                      shown: request.shown, sides: request.sides, fixes: request.change.map { [$0] } ?? [], fixUsed: used)
            case .makeAnother:
                // Worded for what the mini is, read from it.
                let was = Gallery.folder(install.runs, of).map(MiniSettings.load)?.kind ?? .character
                let used = request.change.flatMap { worded($0, cli.defaults, kind: was) }
                if request.newShape {
                    ahead = try jobs.makeNewShape(of: of, as: name, seed: request.seed, change: request.change, changeUsed: used).ahead
                    print("Making \(name), a new 3D shape of \(of).")
                } else {
                    ahead = try jobs.makeAnotherVersion(of: of, as: name, seed: request.seed, change: request.change, changeUsed: used).ahead
                    print("Making \(name), another version of \(of).")
                }
            case .import:
                let into = try request.project.map { try project($0, install) }
                ahead = try jobs.importModel(URL(fileURLWithPath: of), name: name, shown: imported?.shown, sizes: sizes,
                                             kind: kind, project: into)
                print("Importing it as \(imported?.shown ?? name).")
            case .resize, .resizeAll: ahead = try jobs.resize(name: name, sizes: sizes)
            case .retry: ahead = try jobs.retry(name: name)
            }
        } catch {
            return fail("\(error)")
        }
        if ahead != nil, jobs.hold() != nil {
            print("Added to the queue.")
        } else if let ahead {
            let ready = jobs.readyIn(name, queue: jobs.queue.entries(), running: jobs.running(), history: timings.load()) ?? 0
            print("Added to the queue — \(ahead) ahead of it, ready in \(JobProgress.about(ready)).")
        }
        return see(jobs, mine, wait: request.wait, added: added)
    }

    private static func open(_ rest: [String], _ cli: Context) -> Int32 {
        guard rest.count == 1 else { return fail(usage) }
        guard let m = find(rest[0], cli.install) else { return fail(notFound(rest[0])) }
        guard let stl = m.stl else { return fail("\(m.displayName) isn't made yet.") }
        // The slicer picked in the app's Settings: `defaults` are the app's, through the symlink too.
        let slicer = Slicer.preferred(defaults: cli.defaults)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failed: Error?
        Slicer.open(stl, in: slicer) { failed = $0; done.signal() }
        _ = done.wait(timeout: .now() + 30)
        if let failed { return fail("Couldn't open it in \(slicer?.name ?? "your slicer"): \(failed.localizedDescription)") }
        print("Opened \(m.displayName) in \(slicer?.name ?? "your Mac's app for print files").")
        return 0
    }

    /// `mimic export <name> --vtt [--triangles N]`: `--vtt` is the one kind for now (#158); a
    /// print file is what `open` is for.
    private static func export(_ rest: [String], _ cli: Context) -> Int32 {
        var triangles = Tabletop.triangles
        switch Array(rest.dropFirst()) {
        case ["--vtt"]: break
        case let a where a.count == 3 && a[0] == "--vtt" && a[1] == "--triangles":
            guard let n = Int(a[2]), n > 0 else { return fail("--triangles takes a number, like 5000.") }
            triangles = n
        default: return fail(usage)
        }
        guard !rest[0].hasPrefix("-") else { return fail(usage) }
        guard let m = find(rest[0], cli.install) else { return fail(notFound(rest[0])) }
        guard m.stl != nil else { return fail("\(m.displayName) isn't made yet.") }
        let out = URL(fileURLWithPath: "\(m.name).glb")
        do {
            let made = try Tabletop.export(m, to: out, triangles: triangles)
            let size = ByteCountFormatter.string(fromByteCount: Int64(made.bytes), countStyle: .file)
            print("Exported \(m.displayName) for a virtual tabletop: \(out.path), \(made.triangles) triangles, \(made.colour ? "in colour" : "grey"), \(size).")
        } catch { return fail("Couldn't export \(m.displayName): \(error)") }
        return 0
    }

    private static func info(_ rest: [String], _ cli: Context, json: Bool) -> Int32 {
        guard rest.count == 1 else { return fail(usage) }
        let install = cli.install
        let minis = Gallery.list(install.runs)
        guard let m = minis.first(where: { $0.name == Rules.miniName(rest[0]) }) else { return fail(notFound(rest[0])) }
        let waiting = Set(JobQueue(folder: install.queue).entries().map(\.name))
        let info = MiniInfo(m, in: minis, waiting: waiting)
        if json { return printJSON(ListingJSON.Info(info, waiting: waiting)) }
        info.lines.forEach { print($0) }
        return 0
    }

    private static func rename(_ rest: [String], _ cli: Context) -> Int32 {
        let install = cli.install
        guard rest.count == 3, !rest[0].hasPrefix("-"), rest[1] == "--to" else { return fail(usage) }
        let old = Rules.miniName(rest[0]), before = Mini.displayName(old, runs: install.runs)
        do {
            let new = try JobRunner(install: install).rename(old, typed: rest[2])
            print("Renamed \(before) to \(Mini.displayName(new, runs: install.runs)) (\(new)).")
        } catch { return fail("\(error)") }
        return 0
    }

    private static func trash(_ rest: [String], _ cli: Context) -> Int32 {
        guard !rest.isEmpty, !rest.contains(where: { $0.hasPrefix("-") }) else { return fail(usage) }
        let jobs = JobRunner(install: cli.install)
        var code: Int32 = 0
        for text in rest {
            guard let m = find(text, cli.install) else { code = fail(notFound(text)); continue }
            do { try jobs.moveToTrash(m); print("Moved \(m.displayName) to the Trash.") } catch { code = fail("\(error)") }
        }
        return code
    }

    private static func keep(_ rest: [String], _ cli: Context) -> Int32 {
        let install = cli.install
        guard rest.count == 1, !rest[0].hasPrefix("-") else { return fail(usage) }
        let jobs = JobRunner(install: install)
        let minis = Gallery.list(install.runs)
        guard let m = minis.first(where: { $0.name == Rules.miniName(rest[0]) }) else { return fail(notFound(rest[0])) }
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
    }

    private static func stop(_ rest: [String], _ cli: Context) -> Int32 {
        let install = cli.install
        guard rest.isEmpty else { return fail(usage) }
        let jobs = JobRunner(install: install)
        jobs.cleanUpLeftovers()
        switch jobs.stopElsewhere() {
        case .nothing:
            print("Nothing is being made.")
        case .stopped(let s):
            let who = s.displayName(runs: install.runs)
            print(s.kind == .prep ? "Stopped resizing \(who). It keeps its previous size."
                                  : "Stopped making \(who). Nothing was kept. It's in the Trash if you want the pieces.")
        case .ended(let s):
            let who = s.displayName(runs: install.runs)
            print(s.kind == .prep ? "Resizing \(who) had already ended, so it wasn't stopped."
                                  : "Making \(who) had already ended, so it wasn't stopped.")
        case .noAnswer(let s):
            return fail("\(s.displayName(runs: install.runs)) didn't stop. Stop it where it's being made: in Mimic, or with Ctrl-C in the Terminal window making it.")
        }
        return 0
    }

    /// `mimic project create|rename|delete`.
    private static func manageProject(_ rest: [String], _ cli: Context) -> Int32 {
        let install = cli.install
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
    }

    private static func find(_ text: String, _ install: Install) -> Mini? {
        let name = Rules.miniName(text)
        return Gallery.list(install.runs).first { $0.name == name }
    }

    private static func printJSON<T: Encodable>(_ value: T) -> Int32 {
        do { print(try ListingJSON.text(value)) } catch { return fail("\(error)") }
        return 0
    }

    private static func notFound(_ text: String) -> String { "There's no mini called \(text). See them all: mimic list" }

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

    /// The AI helper's edit instruction for a `--change` (#156), or nil to use it as typed:
    /// without a helper that's said nowhere, as the change still works; a failed one says so.
    private static func worded(_ change: String, _ defaults: UserDefaults, kind: MiniKind) -> String? {
        guard let helper = DescriptionHelper.configured(defaults: defaults) else { return nil }
        print("Wording the change…")
        do {
            let used = try helper.rewriteFix(change, kind: kind.rawValue)
            print("✨ Change: \(used)")
            return used
        } catch {
            print("Couldn't word it: \(error) Using your change as it is.")
            return nil
        }
    }

    /// The latest status of this command's own mini, as the runner reports it.
    final class Mine: @unchecked Sendable {
        let runs: URL
        private let lock = NSLock()
        private var mine: String
        private var last: JobStatus?
        private var shown: (String, JobStep)?
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
                let who = s.name == mine ? "" : "\(s.displayName(runs: runs)) (waiting before yours): "
                return "[\(s.step.rawValue)/3] \(who)\(s.step.label)"
            }
            if let line { print(line) }
            if s.openingDrawThings, lock.withLock({ () -> Bool in defer { openingSaid = true }; return !openingSaid }) {
                print("Opening Draw Things…")
            }
        }
    }

    /// Runs this terminal's jobs to the end of its own mini; Ctrl-C (or closing the window, or
    /// `kill`) stops the running job and everything it started, and leaves the queue to the app.
    private static func follow(_ jobs: JobRunner, _ mine: Mine) -> Int32 {
        // A closed Terminal window has nowhere to say it.
        let signals = jobs.stopOnSignals { if $0 != SIGHUP { print("\nStopping…") } }
        defer { signals.forEach { $0.cancel() } }
        if let s = jobs.status { mine.saw(s) }
        jobs.waitUntilDone()
        guard let s = mine.status ?? jobs.status.flatMap({ $0.name == mine.name ? $0 : nil }) else {
            // Stopped (Ctrl-C) before its turn came: it's still waiting.
            print("Stopped. \(Mini.displayName(mine.name, runs: mine.runs)) is still in the queue (mimic queue remove \(mine.name) takes it out).")
            return 130
        }
        let folder = Gallery.folder(jobs.install.runs, s.name) ?? jobs.install.runs.appendingPathComponent(s.name)
        if s.canceled { print("Stopped."); return 130 }
        if s.outcome == .pictureReady {
            print("Its picture is ready to check: \(folder.appendingPathComponent("source.png").path)")
            print("To build its 3D shape: mimic retry \(s.name)")
            return 0
        }
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
    private static func listQueue(_ jobs: JobRunner, history: [TimingRecord], json: Bool = false) -> Int32 {
        let running = jobs.running(), queue = jobs.queue.entries()
        if json {
            let left = running.map { jobs.estimate($0.name, $0.kind, history: history).left($0) } ?? 0
            return printJSON(ListingJSON.Queue(running: running, left: left, held: jobs.hold(),
                                               waiting: jobs.queueTimes(queue, running: running, history: history)))
        }
        if let r = running {
            let left = jobs.estimate(r.name, r.kind, history: history).left(r)
            let importing = Gallery.folder(jobs.install.runs, r.name).map(JobRunner.importing) ?? false
            print("Now: \(JobRunner.doing(r.kind, importing: importing).lowercased()) \(r.name), step \(r.step.rawValue) of 3, \(JobProgress.about(left)) left")
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
    /// What it says goes to prep.log, for people, and to the report beside the print file, for
    /// the job (`PrepReport`).
    private static func prep(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)  // prep.log shows each step as it happens
        // The print file's path, even when the options don't parse: it's the one ending .stl.
        let stl = args.first { $0.hasSuffix(".stl") }.map { URL(fileURLWithPath: $0) }
        do {
            let options = try PrepOptions.parse(args)
            let result = try Prep.run(options, views: true) { print($0) }
            result.lines.forEach { print($0) }
            try PrepReport(warnings: result.warnings).write(beside: URL(fileURLWithPath: options.stl))
            return 0
        } catch {
            if let stl { try? PrepReport(failure: "\(error)").write(beside: stl) }
            return fail(Prep.failure + "\(error)")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
}
