import Foundation
import MimicCore
import UserNotifications

/// The command-line mode: the same engine as the app, for the terminal and for scripts.
enum CLI {
    static let usage = """
    usage:
      mimic make <name> "<description>" [--improve] [options]
      mimic make <name> --image <picture> [--restyle] [options]
      mimic resize <name> [options]
      mimic retry <name>
      mimic list
      mimic models
    options: --height MM  --base MM  --nozzle 0.2|0.4|0.6  --inflate MM  --no-base  --seed N  --model ID
    anything that isn't a character: make … --object  [--size MM (longest side)]  [--add-base]
    --improve: the AI helper chosen in Settings writes a fuller description first
    """

    static func run(_ args: [String]) -> Int32 {
        if args.first == "--probe-notifications" { return probeNotifications() }
        // The job's own steps, each run by a job as its own program: before finding the Mimic
        // folder or stopping leftovers, since this *is* the program named in runs/.job.pid.
        if args.first == "_engine" { return engine(Array(args.dropFirst())) }
        if args.first == "_prep" { return prep(Array(args.dropFirst())) }
        // Run through a symlink (Settings shows how to put one on the PATH), the binary isn't seen as part of
        // its app, so it would read its own empty settings rather than the app's.
        let defaults = Bundle.main.bundleIdentifier == nil ? UserDefaults(suiteName: "com.mimic.app") ?? .standard : .standard
        let install = Install.locate(defaults: defaults)
        Leftover.stop(install.runs)
        var rest = Array(args.dropFirst())
        switch args.first {
        case "list":
            for m in Gallery.list(install.runs) {
                print("\(m.name)\t\(m.stl == nil ? "unfinished" : "ready")\t\(m.madeAt)")
            }
            return 0
        case "models":
            // The app's choice, marked; downloading one is the app's job, where it shows progress.
            let selected = EngineDownload.selected(defaults: defaults)
            for m in EngineDownload.catalogue {
                let state = m.complete(in: install) ? "downloaded" : "not downloaded"
                print("\(m.id == selected.id ? "*" : " ") \(m.id)\t\(m.name)\t\(Checks.gigabytes(m.bytes)) GB\t\(state)\t\(m.summary)")
            }
            print("* = the one Mimic uses. Choose or download one in the Mimic app: Settings → 3D model.")
            return 0
        case "make", "resize", "retry":
            guard let name = rest.first, !name.hasPrefix("-") else { return fail(usage) }
            // Setup downloads the engine in the app, where it can show its progress.
            guard args[0] == "resize" || FileManager.default.isExecutableFile(atPath: install.trellisCLI.path) else {
                return fail("Mimic needs to finish setting up. Open the Mimic app: it downloads what's missing.")
            }
            rest.removeFirst()
            var sizes = Sizes(), image: String?, restyle = false, seed = 42, description: String?, improve = false
            var model = EngineDownload.selected(defaults: defaults)
            var object = false, addBase = false
            while let a = rest.first {
                rest.removeFirst()
                func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
                switch a {
                case "--height", "--size": sizes.height = value()
                case "--object": object = true
                case "--add-base": addBase = true
                case "--base": sizes.base = value()
                case "--nozzle": sizes.nozzle = value()
                case "--inflate": sizes.inflate = value()
                case "--no-base": sizes.noBase = true
                case "--image": image = value()
                case "--restyle": restyle = true
                case "--improve": improve = true
                case "--seed": guard let v = value().flatMap(Int.init) else { return fail("--seed needs a number") }; seed = v
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
            if args[0] == "resize" { object = MiniSettings.load(install.runs.appendingPathComponent(name)).isObject }
            if object {
                if !addBase { sizes.noBase = true }
                // An object's base goes under its whole shadow, as in the app (SizeCard).
                else if sizes.base == nil, let h = sizes.height.flatMap(Double.init) ?? SizeCard.objectSize[sizes.nozzle ?? "0.4"] {
                    sizes.base = SizeCard.text(min(80, max(25, (h * 0.8 / 5).rounded() * 5)))
                }
                if sizes.height == nil { sizes.height = SizeCard.text(SizeCard.objectSize[sizes.nozzle ?? "0.4"] ?? 80) }
            }
            let jobs = JobRunner(install: install)
            do {
                switch args[0] {
                case "make":
                    let picture: PictureSource
                    if improve && image != nil { return fail("--improve works on a description, not --image") }
                    if let image { picture = .image(URL(fileURLWithPath: image)) }
                    else if let description { picture = improve ? improved(description, defaults, kind: object ? .object : .character) : .description(description) }
                    else { return fail(usage) }
                    try jobs.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes,
                                  kind: object ? .object : .character, model: model)
                case "resize": try jobs.resize(name: name, sizes: sizes)
                default: try jobs.retry(name: name)
                }
            } catch {
                return fail("\(error)")
            }
            return follow(jobs)
        default:
            return fail(usage)
        }
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

    /// Prints each step as it starts; Ctrl-C stops the job and everything it started.
    private static func follow(_ jobs: JobRunner) -> Int32 {
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
        interrupt.setEventHandler { print("\nStopping…"); jobs.cancel() }
        interrupt.resume()
        nonisolated(unsafe) var shown = 0
        jobs.onChange = { s in
            if s.running, s.step != shown { shown = s.step; print("[\(s.step)/3] \(JobRunner.label(s.step))") }
        }
        if let s = jobs.status { shown = s.step; print("[\(s.step)/3] \(JobRunner.label(s.step))") }
        jobs.waitUntilDone()
        guard let s = jobs.status else { return 1 }
        let folder = jobs.install.runs.appendingPathComponent(s.name)
        if s.canceled { print("Stopped."); return 130 }
        if s.succeeded {
            print("Done: \(folder.appendingPathComponent("\(s.name).stl").path)")
            if s.fragile { print("Heads up: some thin parts may be fragile. Check it in your slicer before printing.") }
            return 0
        }
        return fail("It didn't finish: \(s.problem ?? "a step failed (exit \(s.exit ?? -1))"). See the logs in \(folder.path)")
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
            return fail("mini_prep: \(error)")
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
