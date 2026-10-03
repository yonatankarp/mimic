import Foundation

/// One thing Mimic depends on, and how to tell whether it's there. `required` ones stop Mimic
/// working; the rest only switch off a feature (drawing pictures, opening a slicer).
public struct Check: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let required: Bool
    public let fix: String
    /// Blocks (it may start a program or ask Draw Things), so run it off the main thread.
    /// Never cached: a cached answer is how a check keeps saying yes after the thing has gone.
    public let run: @Sendable () -> CheckResult
}

public struct CheckResult: Sendable, Equatable {
    public let id: String
    /// Can differ from the check's label ("Free disk space (120 GB)").
    public let label: String
    public let required: Bool
    public let ok: Bool
    public let fix: String
}

/// The Settings health checks, ported from the web version. Every dependency is an input so
/// tests can build a Mac where each check is red, and one where it's green.
public struct Checks: Sendable {
    public typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> (status: Int32, output: String)?

    public var install: Install
    /// The model set minis are made with: its files are what the models check wants.
    public var model: EngineModel
    public var appFolders: [URL]
    public var drawThings: DrawThings
    /// Settings → Open Draw Things when needed: then Draw Things being closed is fine.
    public var autoOpen: Bool
    /// The online picture service Settings chose (#247): then its key is checked instead of Draw Things.
    public var online: (any OnlineImages)?
    public var run: Runner
    public var freeBytes: @Sendable (URL) -> Int64?

    public init(install: Install,
                model: EngineModel,
                appFolders: [URL] = Slicer.appFolders(),
                drawThings: DrawThings = DrawThings(),
                autoOpen: Bool = DrawThingsApp.enabled(),
                online: (any OnlineImages)? = OnlineService.configured(defaults: .standard),
                run: @escaping Runner = Checks.execute,
                freeBytes: @escaping @Sendable (URL) -> Int64? = Checks.freeBytes) {
        self.install = install; self.model = model; self.appFolders = appFolders; self.drawThings = drawThings; self.autoOpen = autoOpen
        self.online = online; self.run = run; self.freeBytes = freeBytes
    }

    /// The API check's label while Draw Things is closed and Mimic will open it.
    public static let opensWhenNeeded = "Draw Things opens when needed"

    public static let drawThingsIDs: Set<String> = ["drawthings-app", "drawthings-api", "drawthings-model"]
    /// The online service's one check, in their place when it makes the pictures.
    public static let onlineID = "images-online"
    public static func onlineLabel(_ service: OnlineService) -> String { "\(service.name) key works" }

    public var all: [Check] {
        let s = self
        return [
            check("engine", "3D engine", true,
                  "The 3D engine is missing or won't start. Repair downloads it again.") { s.engineStarts() },
            check("models", "3D model files (\(model.name))", true,
                  "Some of the 3D model files are missing. Download fetches only what's missing (up to \(Checks.gigabytes(model.bytes)) GB).") { s.modelsComplete() },
            Check(id: "space", label: "Free disk space", required: true,
                  fix: "Free up some space: each mini takes about 150 MB while it's being made.") {
                let gb = Double(s.freeBytes(s.install.runs) ?? 0) / 1e9
                return CheckResult(id: "space", label: "Free disk space (\(Int(gb.rounded())) GB)", required: true, ok: gb >= 5,
                                   fix: "Free up some space: each mini takes about 150 MB while it's being made.")
            },
        ] + pictures + [
            check("slicer", "A slicer to print with", false,
                  "Install a slicer such as Bambu Studio, OrcaSlicer, PrusaSlicer or Cura. "
                  + "Until then Mimic opens minis with your Mac's default app for 3D files.") {
                !Slicer.installed(in: s.appFolders).isEmpty
            },
        ]
    }

    /// What makes the pictures: Draw Things' checks, or the online service's key.
    private var pictures: [Check] {
        let s = self
        if let online {
            let label = Self.onlineLabel(online.service)
            return [Check(id: Self.onlineID, label: label, required: false, fix: "") {
                let why: String? = { do { try online.check(); return nil } catch { return "\(error)" } }()
                return CheckResult(id: Self.onlineID, label: label, required: false, ok: why == nil, fix: why ?? "")
            }]
        }
        return [
            check("drawthings-app", "Draw Things app", false, "Install Draw Things from the Mac App Store. It's free.") {
                s.drawThingsInstalled()
            },
            Check(id: "drawthings-api", label: "Draw Things is open and connected", required: false, fix: Self.apiFix) {
                // With the command line tool, the app and its API server aren't needed at all.
                if s.drawThings.cli != nil {
                    return CheckResult(id: "drawthings-api", label: Self.commandLine, required: false, ok: true, fix: Self.apiFix)
                }
                // Closed is fine when Mimic opens it: informative, not something to fix.
                let connected = s.drawThings.reachable()
                let ok = connected || (s.autoOpen && s.drawThingsInstalled())
                return CheckResult(id: "drawthings-api", label: connected || !ok ? "Draw Things is open and connected" : Self.opensWhenNeeded,
                                   required: false, ok: ok, fix: Self.apiFix)
            },
            check("drawthings-model", "FLUX.2 Klein model in Draw Things", false,
                  "In Draw Things' model list, search for FLUX.2 Klein and download it.") { s.drawThings.model() != nil },
        ]
    }

    /// The API check's label when Mimic's `draw-things-cli` makes the pictures.
    public static let commandLine = "Draw Things connected through its command line tool"
    static let apiFix = "Open Draw Things, then Settings → Advanced → API Server: turn it on, choose HTTP, port 7860."

    func drawThingsInstalled() -> Bool { appFolders.contains { isDirectory($0.appendingPathComponent("Draw Things.app")) } }

    private func check(_ id: String, _ label: String, _ required: Bool, _ fix: String,
                       _ test: @escaping @Sendable () -> Bool) -> Check {
        Check(id: id, label: label, required: required, fix: fix) {
            CheckResult(id: id, label: label, required: required, ok: test(), fix: fix)
        }
    }

    /// Whether the 3D engine is the pinned build and launches (~10 ms): present but broken, like
    /// a copy whose libraries went missing, is red, and so is an older build, which Repair replaces.
    func engineStarts() -> Bool {
        let version = try? String(contentsOf: install.engine.appendingPathComponent("VERSION"), encoding: .utf8)
        return version?.hasPrefix(EngineDownload.version + " ") == true
            && isFile(install.trellisCLI) && run(install.trellisCLI.path, ["--help"], 10)?.status == 0
    }

    /// Every file trellis-cli loads for the chosen model, at its full size (setup checks their
    /// sha256 too).
    func modelsComplete() -> Bool { model.complete(in: install) }

    /// "8.1": sizes on screen are decimal GB, one place.
    public static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }

    private func isFile(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue
    }

    private func isDirectory(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    /// Runs a program with the environment jobs get, and returns its exit status and output.
    /// nil if it can't start or is still running after `timeout` (then it's killed: a hung
    /// program must not hang Settings). Output stops being read once the program exits, so
    /// something it left running with the pipe open neither hangs Settings nor uses up the time
    /// its exit needs to be seen (a busy Mac then showed a red check).
    public static let execute: Runner = { executable, arguments, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = Tools.childEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        defer { try? out.fileHandleForReading.close() }
        let deadline = Date().addingTimeInterval(timeout)
        // Read to the end first: waiting first can deadlock on a full pipe.
        let fd = out.fileHandleForReading.fileDescriptor
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while deadline.timeIntervalSinceNow > 0 {
            // Short waits, to notice the exit. Once it has exited, everything it wrote is
            // already in the pipe: take that and stop.
            let exited = !p.isRunning
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let n = poll(&ready, 1, exited ? 0 : min(Int32(deadline.timeIntervalSinceNow * 1000) + 1, 50))
            if n < 0 && errno != EINTR { break }
            if n == 0 && exited { break }
            if n <= 0 { continue }
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read < 0 && errno == EINTR { continue }
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        while p.isRunning && deadline.timeIntervalSinceNow > 0 { usleep(10_000) }
        if p.isRunning {
            // SIGTERM first, then SIGKILL for a program that ignores it.
            p.terminate()
            let grace = Date().addingTimeInterval(1)
            while p.isRunning && grace.timeIntervalSinceNow > 0 { usleep(10_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            return nil
        }
        p.waitUntilExit()
        if p.terminationReason == .uncaughtSignal { return nil }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Free space on the disk `url` is on. Asked of the nearest folder that exists: on a new Mac
    /// neither the minis folder nor the engine's is there yet.
    public static let freeBytes: @Sendable (URL) -> Int64? = { url in
        var url = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}

/// One loop for however many want it (#347): the first to `join` starts it, and it's cancelled
/// once the last has gone. Settings, New Mini and Setup each watch Draw Things while they're open,
/// and two can be open at once (New Mini's Open Settings), so each running its own loop checked
/// Draw Things side by side.
@MainActor public final class SharedLoop {
    private var joined = 0
    private var loop: Task<Void, Never>?

    public init() {}

    /// Until the calling task is cancelled, as a view's `.task` is when the view goes. `body` runs
    /// only when nobody else's is running already.
    public func join(_ body: @escaping @MainActor () async -> Void) async {
        joined += 1
        if loop == nil { loop = Task { await body() } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        joined -= 1
        if joined == 0 { loop?.cancel(); loop = nil }
    }
}
