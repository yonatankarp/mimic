import Foundation
import MimicCore
import UserNotifications

/// The command-line mode: the same engine as the app, for the terminal and for scripts.
enum CLI {
    static let usage = """
    usage:
      mimic make <name> "<description>" [--improve] [options]
      mimic make <name> --image <picture> [--restyle] [options]
      mimic make-another <name> [--seed N]
      mimic resize <name> [options]
      mimic retry <name>
      mimic list
      mimic projects
      mimic move <name> --project "<project>" | --unsorted
      mimic models
      mimic queue
      mimic queue remove <name>
      mimic --version                which Mimic this is (also -v)
      mimic --help                   this list (also -h)
    options: --height MM  --scale 28|32|35|54|75  --base MM  --nozzle 0.2|0.4|0.6  --inflate MM  --no-base  --base-shape round|square|hex  --base-style plain|stone|wood|cobble  --magnet 5x2|6x2|8x3|none  --seed N  --model ID
    anything that isn't a character: make … --object  [--size MM (longest side)]  [--add-base]
    make … --project "<project>": into that project (made if it's new); a project is a folder in the minis folder
    make-another: the same picture or description and settings with a new seed, next to it ("<name>-2")
    --improve: the AI helper chosen in Settings writes a fuller description first
    --wait: while another mini is being made, make, resize and retry join the queue and return;
            --wait stays until this one is made
    """

    static func run(_ args: [String]) -> Int32 {
        if args.first == "--probe-notifications" { return probeNotifications() }
        if ["--version", "-v", "version"].contains(args.first) { print(BuildInfo.line); return 0 }
        if ["--help", "-h", "help"].contains(args.first) { print(usage); return 0 }
        // The job's own steps, each run by a job as its own program: before finding the Mimic
        // folder or stopping leftovers, since this *is* the program named in runs/.job.pid.
        if args.first == "_engine" { return engine(Array(args.dropFirst())) }
        if args.first == "_prep" { return prep(Array(args.dropFirst())) }
        // Run through a symlink (Settings shows how to put one on the PATH), the binary isn't seen as part of
        // its app, so it would read its own empty settings rather than the app's.
        let defaults = Bundle.main.bundleIdentifier == nil ? UserDefaults(suiteName: "com.mimic.app") ?? .standard : .standard
        let install = Install.locate(defaults: defaults)
        let timings = Timings.standard()
        var rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            JobRunner(install: install).cleanUpLeftovers()
            let queue = JobQueue(runs: install.runs).entries()
            let minis = Gallery.list(install.runs), projects = Gallery.projects(install.runs)
            func row(_ m: Mini, _ indent: String) {
                let state = queue.contains { $0.name == m.name } ? "waiting" : m.stl == nil ? "unfinished" : "ready"
                print("\(indent)\(m.name)\t\(state)\t\(m.created)")
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
            let name = rest[0]
            let target: String?
            switch Array(rest.dropFirst()) {
            case ["--unsorted"]: target = nil
            case let a where a.count == 2 && a[0] == "--project": 
                do { target = try project(a[1], install) } catch { return fail("\(error)") }
            default: return fail(usage)
            }
            do { try JobRunner(install: install).move(mini: name, toProject: target) } catch { return fail("\(error)") }
            print("Moved \(Mini.displayName(name)) to \(target ?? "Unsorted").")
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
            jobs.cleanUpLeftovers()
            if rest.first == "remove" {
                guard rest.count == 2 else { return fail("usage: mimic queue remove <name>") }
                do {
                    guard try jobs.remove(rest[1]) else { return fail("\(rest[1]) isn't waiting in the queue.") }
                } catch { return fail("\(error)") }
                print("Took \(Mini.displayName(rest[1])) out of the queue.")
                return 0
            }
            guard rest.isEmpty else { return fail(usage) }
            return listQueue(jobs, history: timings.load())
        case "make", "resize", "retry", "make-another":
            guard let of = rest.first, !of.hasPrefix("-") else { return fail(usage) }
            // make-another makes a new mini, next to `of`.
            let name = args[0] == "make-another" ? Gallery.nextVersionName(install.runs, of) : of
            // Setup downloads the engine in the app, where it can show its progress.
            guard args[0] == "resize" || FileManager.default.isExecutableFile(atPath: install.trellisCLI.path) else {
                return fail("Mimic needs to finish setting up. Open the Mimic app: it downloads what's missing.")
            }
            rest.removeFirst()
            var sizes = Sizes(), image: String?, restyle = false, seed = 42, description: String?, improve = false
            var model = EngineDownload.selected(defaults: defaults)
            var object = false, addBase = false, wait = false, projectName: String?, seedGiven = false, shapeGiven = false, styleGiven = false, magnetGiven = false
            var scale: Int?
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
                case "--restyle": restyle = true
                case "--improve": improve = true
                case "--wait": wait = true
                case "--seed": guard let v = value().flatMap(Int.init) else { return fail("--seed needs a number") }; seed = v; seedGiven = true
                case "--project": guard let v = value() else { return fail("--project needs a project's name") }; projectName = v
                case "--model":
                    guard let v = value().flatMap(EngineDownload.model) else {
                        return fail("--model needs one of: \(EngineDownload.catalogue.map(\.id).joined(separator: ", ")) (see mimic models)")
                    }
                    model = v
                default:
                    guard description == nil, !a.hasPrefix("-") else { return fail("unknown option: \(a)\n\(usage)") }
                    description = a
                }
            }
            // An object has no round base unless asked for one; a resize keeps what the mini is.
            if args[0] == "resize", let saved = Gallery.folder(install.runs, name).map(MiniSettings.load) {
                object = saved.isObject
                // A hex mini on a stone floor resized stays that, as in the app.
                let was = saved.made ?? saved.requested
                if !shapeGiven, let s = was?.shape { sizes.shape = s }
                if !styleGiven, let s = was?.style { sizes.style = s }
                if !magnetGiven { sizes.magnet = was?.magnet }
            }
            if projectName != nil && args[0] != "make" { return fail("--project is for mimic make; mimic move moves a mini") }
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
            // This terminal runs the queue only until its own mini is made; the app runs the rest.
            jobs.keepGoing = { $0.contains { $0.name == name } }
            let mine = Mine(name: name)
            jobs.onChange = { mine.saw($0) }
            let added = Date()
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
                                          kind: object ? .object : .character, model: model, project: into)
                case "make-another":
                    ahead = try jobs.makeAnotherVersion(of: of, as: name, seed: seedGiven ? seed : nil).ahead
                    print("Making \(name), another version of \(of).")
                case "resize": ahead = try jobs.resize(name: name, sizes: sizes)
                default: ahead = try jobs.retry(name: name)
                }
            } catch {
                return fail("\(error)")
            }
            if let ahead {
                let ready = jobs.queueTimes(jobs.queue.entries(), running: jobs.running(), history: timings.load())
                    .first { $0.entry.name == name }?.ready ?? 0
                print("Added to the queue — \(ahead) ahead of it, ready in \(JobProgress.about(ready)).")
            }
            // Running here (this one, or one that was waiting before it): see it through.
            if jobs.status?.running == true { return follow(jobs, mine) }
            guard wait else {
                print("It starts when the one before it is done, in whichever Mimic is making that. If none is open by then, it starts the next time you open Mimic. See the queue: mimic queue")
                return 0
            }
            return watch(jobs, mine, added: added)
        default:
            return fail(usage)
        }
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
        let name: String
        private let lock = NSLock()
        private var last: JobStatus?
        private var shown: (String, Int)?
        private var openingSaid = false
        init(name: String) { self.name = name }
        var status: JobStatus? { lock.withLock { last } }

        /// Prints each step as it starts, naming the mini when it isn't this one.
        func saw(_ s: JobStatus) {
            let line: String? = lock.withLock {
                if s.name == name { last = s }
                guard s.running, shown.map({ $0 != (s.name, s.step) }) ?? true else { return nil }
                shown = (s.name, s.step)
                let who = s.name == name ? "" : "\(Mini.displayName(s.name)) (waiting before yours): "
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
        guard let s = mine.status else {
            // Stopped (Ctrl-C) before its turn came: it's still waiting.
            print("Stopped. \(Mini.displayName(mine.name)) is still in the queue (mimic queue remove \(mine.name) takes it out).")
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
            print("Now: \(r.kind == .prep ? "resizing" : "making") \(r.name), step \(r.step) of 3, \(JobProgress.about(left)) left")
        } else {
            print(queue.isEmpty ? "Nothing is being made." : "Nothing is being made right now: the queue starts when you open Mimic.")
        }
        for (i, row) in jobs.queueTimes(queue, running: running, history: history).enumerated() {
            print("\(i + 1). \(row.entry.name)\t\(row.entry.job == .prep ? "resize" : "make")\ttakes \(JobProgress.about(row.estimate.total))\tready in \(JobProgress.about(row.ready))")
        }
        return 0
    }

    /// Step 2 of a job, run by the job itself (not for people, so not in the usage):
    /// `mimic _engine <source.png> <model.glb> --seed N --engine <dir> [--model ID]`.
    private static func engine(_ args: [String]) -> Int32 {
        var rest = args, seed = 42, engine: String?, files: [String] = [], model = EngineDownload.standard
        while let a = rest.first {
            rest.removeFirst()
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
                            engine: URL(fileURLWithPath: engine), model: model, environment: ProcessInfo.processInfo.environment) {
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
