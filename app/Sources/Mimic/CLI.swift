import Foundation
import MimicCore
import UserNotifications

/// The command-line mode: the same engine as the app, for the terminal and for scripts.
enum CLI {
    static let usage = """
    usage:
      mimic make <name> "<description>" [options]
      mimic make <name> --image <picture> [--restyle] [options]
      mimic resize <name> [options]
      mimic retry <name>
      mimic list
    options: --height MM  --base MM  --nozzle 0.2|0.4|0.6  --inflate MM  --no-base  --seed N
    """

    static func run(_ args: [String]) -> Int32 {
        if args.first == "--probe-notifications" { return probeNotifications() }
        // Before finding the Mimic folder or stopping leftovers: this *is* the running job's
        // program (named in runs/.job.pid), and it's told where the engine is.
        if args.first == "_engine" { return engine(Array(args.dropFirst())) }
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
        case "make", "resize", "retry":
            guard let name = rest.first, !name.hasPrefix("-") else { return fail(usage) }
            // Setup downloads the engine in the app, where it can show its progress.
            guard args[0] == "resize" || EngineDownload.present(install) else { return fail("Mimic needs to finish setting up. Open the Mimic app: it downloads what's missing.") }
            rest.removeFirst()
            var sizes = Sizes(), image: String?, restyle = false, seed = 42, description: String?
            while let a = rest.first {
                rest.removeFirst()
                func value() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
                switch a {
                case "--height": sizes.height = value()
                case "--base": sizes.base = value()
                case "--nozzle": sizes.nozzle = value()
                case "--inflate": sizes.inflate = value()
                case "--no-base": sizes.noBase = true
                case "--image": image = value()
                case "--restyle": restyle = true
                case "--seed": guard let v = value().flatMap(Int.init) else { return fail("--seed needs a number") }; seed = v
                default:
                    guard description == nil, !a.hasPrefix("-") else { return fail("unknown option: \(a)\n\(usage)") }
                    description = a
                }
            }
            let jobs = JobRunner(install: install)
            do {
                switch args[0] {
                case "make":
                    let picture: PictureSource
                    if let image { picture = .image(URL(fileURLWithPath: image)) }
                    else if let description { picture = .description(description) }
                    else { return fail(usage) }
                    try jobs.make(name: name, picture: picture, restyle: restyle, seed: seed, sizes: sizes)
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
    /// `mimic _engine <source.png> <model.glb> --seed N --engine <dir>`.
    private static func engine(_ args: [String]) -> Int32 {
        var rest = args, seed = 42, engine: String?, files: [String] = []
        while let a = rest.first {
            rest.removeFirst()
            switch a {
            case "--seed": guard let v = rest.first.flatMap(Int.init) else { return fail("--seed needs a number") }; seed = v; rest.removeFirst()
            case "--engine": guard let v = rest.first else { return fail("--engine needs a folder") }; engine = v; rest.removeFirst()
            default: files.append(a)
            }
        }
        guard files.count == 2, let engine else { return fail("usage: mimic _engine <source.png> <model.glb> --seed N --engine <dir>") }
        let out = FileHandle.standardOutput
        do {
            try Engine.make(source: URL(fileURLWithPath: files[0]), output: URL(fileURLWithPath: files[1]), seed: seed,
                            engine: URL(fileURLWithPath: engine), environment: ProcessInfo.processInfo.environment) {
                out.write(Data(($0 + "\n").utf8))
            }
            return 0
        } catch {
            _ = fail("\(error)")
            return 1
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
