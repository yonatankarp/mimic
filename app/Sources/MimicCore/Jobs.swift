import Darwin
import Foundation

/// Where a job is, for the progress window and `mimic make`.
public struct JobStatus: Equatable, Sendable {
    public var name: String
    public var kind: JobKind
    public var step: Int
    public var started: Date
    public var running = true
    public var canceled = false
    public var exit: Int32?
    public var problem: String?
    public var fragile = false
    public var succeeded: Bool { !running && !canceled && exit == 0 }
}

/// Where the picture for a new mini comes from.
public enum PictureSource: Sendable {
    case image(URL)
    case description(String)
}

/// Runs one job at a time: making a mini (three steps) or resizing one (print prep only).
///
/// A job's programs run in their own session (GroupProcess) so Stop ends all of them. While a
/// job runs, runs/.job.lock is held, which the web version checks too, and runs/.job.pid names
/// the running program and its start time so a job orphaned by a crash can be stopped safely.
public final class JobRunner: @unchecked Sendable {
    public let install: Install
    let tools: Tools
    let drawThings: DrawThings
    let trash: @Sendable (URL) throws -> Void

    private let lock = NSLock()
    private var current: JobStatus?
    private var process: GroupProcess?
    private var lockFD: Int32 = -1
    private var finished = DispatchSemaphore(value: 0)
    public var onChange: (@Sendable (JobStatus) -> Void)?

    public init(install: Install, tools: Tools? = nil, drawThings: DrawThings = DrawThings(),
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.install = install
        self.tools = tools ?? Tools.resolve(install)
        self.drawThings = drawThings
        self.trash = trash
    }

    public var status: JobStatus? { lock.withLock { current } }

    // MARK: Starting

    /// Makes a new mini. Everything is checked before anything is written.
    public func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes) throws {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        _ = try sizes.flags()
        let folder = install.runs.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.glb").path) { throw RequestError.nameTaken(name) }
        try claim(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var settings = MiniSettings()
            switch picture {
            case .image(let url):
                let upload = folder.appendingPathComponent("upload.img")
                try? FileManager.default.removeItem(at: upload)
                try FileManager.default.copyItem(at: url, to: upload)
                settings.source = .image
            case .description(let text):
                settings.source = .desc; settings.desc = text
            }
            settings.restyle = restyle; settings.seed = seed; settings.requested = sizes
            try MiniSettings.update(folder) { s in
                s.source = settings.source; s.desc = settings.desc; s.restyle = restyle; s.seed = seed; s.requested = sizes
            }
            try begin(.generate, folder: folder)
        } catch { release(); throw error }
    }

    /// Remakes the print file of an existing mini with new sizes (about 30 seconds).
    public func resize(name: String, sizes: Sizes) throws {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        _ = try sizes.flags()
        let folder = install.runs.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.glb").path) else { throw RequestError.noModelYet }
        try claim(name)
        do {
            try MiniSettings.update(folder) { $0.requested = sizes }
            try begin(.prep, folder: folder)
        } catch { release(); throw error }
    }

    /// Runs a failed mini again, from what it saved: a resize if the 3D model exists, else all
    /// three steps.
    public func retry(name: String) throws {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        let folder = install.runs.appendingPathComponent(name)
        guard MiniSettings.load(folder).requested != nil else { throw RequestError.nothingToRetry }
        try claim(name)
        do {
            let hasModel = FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.glb").path)
            try begin(hasModel ? .prep : .generate, folder: folder)
        } catch { release(); throw error }
    }

    /// Stops the running job and everything it started. False when nothing is running.
    @discardableResult
    public func cancel() -> Bool {
        let p: GroupProcess? = lock.withLock {
            guard current?.running == true else { return nil as GroupProcess? }
            current?.canceled = true
            return process
        }
        guard status?.canceled == true else { return false }
        drawThings.cancel()
        if let p { DispatchQueue.global().async { p.terminateGroup() } }
        return true
    }

    /// For the command line and tests.
    public func waitUntilDone() {
        guard status?.running == true else { return }
        finished.wait()
    }

    // MARK: Running

    private func claim(_ name: String) throws {
        try lock.withLock {
            if let c = current, c.running { throw RequestError.busy(c.name) }
            try? FileManager.default.createDirectory(at: install.runs, withIntermediateDirectories: true)
            let fd = open(install.runs.appendingPathComponent(".job.lock").path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if fd >= 0 { close(fd) }
                throw RequestError.busy("another Mimic window")
            }
            lockFD = fd
            current = JobStatus(name: name, kind: .prep, step: 0, started: Date())
        }
    }

    private func release() {
        lock.withLock {
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
            if current?.step == 0 { current = nil }  // claimed but never started
        }
    }

    private func begin(_ kind: JobKind, folder: URL) throws {
        let settings = MiniSettings.load(folder)
        let plan = try Pipeline.plan(kind, folder: folder, settings: settings, tools: tools)
        let log = folder.appendingPathComponent("\(kind.rawValue).job.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        lock.withLock {
            current = JobStatus(name: folder.lastPathComponent, kind: kind, step: plan[0].number, started: Date())
            finished = DispatchSemaphore(value: 0)
        }
        notify()
        Thread.detachNewThread { [self] in execute(plan, kind: kind, folder: folder, log: log, requested: settings.requested) }
    }

    private func execute(_ plan: [(number: Int, step: Step)], kind: JobKind, folder: URL, log: URL, requested: Sizes?) {
        var code: Int32 = 0
        var problem: String?
        // prep.log is appended to on every run, so only this run's part says whether it's fragile.
        let prepLog = folder.appendingPathComponent("prep.log")
        let prepLogStart = (try? FileManager.default.attributesOfItem(atPath: prepLog.path)[.size] as? UInt64) ?? 0
        for (number, step) in plan {
            if status?.canceled == true { break }
            lock.withLock { current?.step = number }
            notify()
            append(log, "[\(number)/3] \(Self.label(number))\n")
            do {
                code = try run(step)
            } catch {
                code = 1
                problem = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            }
            if code != 0 { break }
        }
        let canceled = status?.canceled == true
        if canceled {
            code = code == 0 ? -15 : code
            if kind == .generate { try? trash(folder) }  // a half-made new mini is clutter, not a result
        } else if code == 0, let requested {
            try? MiniSettings.update(folder) { $0.made = requested }  // "Now: …" shows only what a finished run made
        }
        let thisRun: String = {
            guard let h = try? FileHandle(forReadingFrom: prepLog) else { return "" }
            defer { try? h.close() }
            try? h.seek(toOffset: prepLogStart)
            return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        }()
        let fragile = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("mini_prep: WARNING")
            || thisRun.contains("mini_prep: WARNING")
        lock.withLock {
            current?.running = false
            current?.exit = code
            current?.problem = canceled ? nil : problem
            current?.fragile = fragile && code == 0
            process = nil
        }
        Leftover.clear(install.runs)
        release()
        notify()
        finished.signal()
    }

    private func run(_ step: Step) throws -> Int32 {
        switch step {
        case let .copyPicture(from, to):
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
            return 0
        case let .drawCharacter(description, seed, to):
            try drawThings.draw(description: description, seed: seed).write(to: to, options: .atomic)
            return 0
        case let .sculptPicture(from, seed, to):
            try drawThings.sculpt(picture: from, seed: seed).write(to: to, options: .atomic)
            return 0
        case let .run(executable, arguments, directory, log):
            let p = try GroupProcess(executable: executable, arguments: arguments, environment: tools.environment,
                                     workingDirectory: directory, log: log.path)
            let stopNow = lock.withLock { () -> Bool in process = p; return current?.canceled == true }
            Leftover.record(pid: p.pid, runs: install.runs)
            if stopNow { p.terminateGroup() }  // Stop pressed while the program was starting
            return p.wait()
        }
    }

    private func append(_ log: URL, _ text: String) {
        guard let h = try? FileHandle(forWritingTo: log) else { return }
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    }

    private func notify() {
        if let s = status { onChange?(s) }
    }

    public static func label(_ step: Int) -> String {
        ["", "Getting the picture ready", "Building the 3D shape", "Making the print-ready file"][max(0, min(3, step))]
    }
}

/// The record of a running job's program, so one orphaned by a crash can be stopped on the next
/// launch. It holds the pid *and* the program's start time: a pid alone may have been reused by
/// an unrelated program after a reboot, and stopping that would be far worse than a leftover.
public enum Leftover {
    static func file(_ runs: URL) -> URL { runs.appendingPathComponent(".job.pid") }

    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func record(pid: pid_t, runs: URL) {
        guard let t = startTime(pid) else { return }
        try? "\(pid) \(t)".write(to: file(runs), atomically: true, encoding: .utf8)
    }

    static func clear(_ runs: URL) { try? FileManager.default.removeItem(at: file(runs)) }

    /// Stops a job left running by a crashed Mimic. True when one was found and stopped.
    @discardableResult
    public static func stop(_ runs: URL) -> Bool {
        defer { clear(runs) }
        guard let text = try? String(contentsOf: file(runs), encoding: .utf8) else { return false }
        let parts = text.split(separator: " ").compactMap { UInt64($0) }
        guard parts.count == 2, let pid = pid_t(exactly: parts[0]), startTime(pid) == parts[1] else { return false }
        kill(-pid, SIGTERM)
        for _ in 0..<100 where kill(-pid, 0) == 0 { usleep(50_000) }
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        return true
    }
}
