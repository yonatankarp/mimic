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
    public var appFolders: [URL]
    public var drawThings: DrawThings
    /// Where to look for Blender: the same PATH jobs run with.
    public var path: String
    public var run: Runner
    public var freeBytes: @Sendable (URL) -> Int64?

    public init(install: Install,
                appFolders: [URL] = Slicer.appFolders(),
                drawThings: DrawThings = DrawThings(),
                path: String = Tools.childEnvironment()["PATH"]!,
                run: @escaping Runner = Checks.execute,
                freeBytes: @escaping @Sendable (URL) -> Int64? = Checks.freeBytes) {
        self.install = install; self.appFolders = appFolders; self.drawThings = drawThings
        self.path = path; self.run = run; self.freeBytes = freeBytes
    }

    static let reinstall = "Run Install Mimic again: it only adds what's missing."
    public static let drawThingsIDs: Set<String> = ["drawthings-app", "drawthings-api", "drawthings-model"]

    public var all: [Check] {
        let s = self
        return [
            check("engine", "3D engine", true, Self.reinstall) { s.engineStarts() },
            check("models", "3D model files", true, Self.reinstall + " This part downloads 8.4 GB.") {
                s.isFile(s.install.engine.appendingPathComponent("models/pixal3d-sv/pixal3d_shape_flow_1024_sv.gguf"))
            },
            check("helpers", "Mimic's helper tools", true, Self.reinstall) { s.isFile(s.install.labPython) },
            check("blender", "Blender (makes the print file)", true,
                  "Blender is missing or won't start. Run Install Mimic again, or install Blender from blender.org.") {
                s.blenderStarts()
            },
            Check(id: "space", label: "Free disk space", required: true,
                  fix: "Free up some space: each mini takes about 150 MB while it's being made.") {
                let gb = Double(s.freeBytes(s.install.runs) ?? 0) / 1e9
                return CheckResult(id: "space", label: "Free disk space (\(Int(gb.rounded())) GB)", required: true, ok: gb >= 5,
                                   fix: "Free up some space: each mini takes about 150 MB while it's being made.")
            },
            check("drawthings-app", "Draw Things app", false, "Install Draw Things from the Mac App Store. It's free.") {
                s.appFolders.contains { s.isDirectory($0.appendingPathComponent("Draw Things.app")) }
            },
            check("drawthings-api", "Draw Things is open and connected", false,
                  "Open Draw Things, then Settings → Advanced → API Server: turn it on, choose HTTP, port 7860.") {
                s.drawThings.reachable()
            },
            check("drawthings-model", "FLUX.2 Klein model in Draw Things", false,
                  "In Draw Things' model list, search for FLUX.2 Klein and download it.") { s.drawThings.model() != nil },
            check("slicer", "A slicer to print with", false,
                  "Install a slicer such as Bambu Studio, OrcaSlicer, PrusaSlicer or Cura. "
                  + "Until then Mimic opens minis with your Mac's default app for 3D files.") {
                !Slicer.installed(in: s.appFolders).isEmpty
            },
        ]
    }

    private func check(_ id: String, _ label: String, _ required: Bool, _ fix: String,
                       _ test: @escaping @Sendable () -> Bool) -> Check {
        Check(id: id, label: label, required: required, fix: fix) {
            CheckResult(id: id, label: label, required: required, ok: test(), fix: fix)
        }
    }

    /// Whether the 3D engine launches (~10 ms): present but broken, like a copy whose libraries
    /// went missing, is red.
    func engineStarts() -> Bool {
        let cli = install.engine.appendingPathComponent("build/trellis-cli")
        return isFile(cli) && run(cli.path, ["--help"], 10)?.status == 0
    }

    /// Whether Blender actually runs, not just whether a `blender` exists: Homebrew's launcher
    /// outlives the app, so after Blender.app was removed a `which` check still said yes while
    /// every print prep died at start-up. Found the way jobs find it.
    func blenderStarts() -> Bool {
        guard let exe = Tools.which("blender", path: path), let r = run(exe, ["--version"], 30) else { return false }
        return r.status == 0 && r.output.contains("Blender")
    }

    private func isFile(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && !dir.boolValue
    }

    private func isDirectory(_ u: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
    }

    /// Runs a program with the environment jobs get, and returns its exit status and output.
    /// nil if it can't start or outlives `timeout` (then it's killed: a hung Blender must not
    /// hang Settings).
    public static let execute: Runner = { executable, arguments, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = Tools.childEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Read to the end first: waiting first can deadlock on a full pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        if p.terminationReason == .uncaughtSignal { return nil }
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public static let freeBytes: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}
