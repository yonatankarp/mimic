import Darwin
import Foundation

/// One job waiting its turn. A new mini's folder, settings.json and picture are written when it
/// joins the queue, so all it needs here is its name; a resize keeps its sizes here until it
/// starts, so a mini waiting to be resized still shows (and keeps) the size it has now.
public struct QueueEntry: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var job: JobKind
    public var added: Date
    public var sizes: Sizes?
    public var id: String { name }

    public init(name: String, job: JobKind, added: Date = Date(), sizes: Sizes? = nil) {
        self.name = name; self.job = job; self.added = added; self.sizes = sizes
    }
}

/// Where Move puts a waiting job: first (the next to start), last, or a place counted from 1.
public enum QueuePlace: Equatable, Sendable {
    case front, end
    case position(Int)

    /// `front`, `end` or a number, as `mimic queue move --to` takes it.
    public init?(_ text: String) {
        switch text.lowercased() {
        case "front", "first": self = .front
        case "end", "last": self = .end
        default:
            guard let n = Int(text), n >= 1 else { return nil }
            self = .position(n)
        }
    }
}

/// Why the queue's next job waits although nothing is running.
public enum QueueHold: Sendable, Equatable {
    /// Paused, in this Mimic or another, or with `mimic queue pause`.
    case paused
    /// On battery, with Start minis only when plugged in on.
    case battery

    /// What the queue is doing, in words: the popover, the menus and `mimic queue`.
    public var sentence: String {
        switch self {
        case .paused: "The queue is paused. Resume it to carry on."
        case .battery: "Your Mac is on battery, so the queue carries on when it's plugged in."
        }
    }
}

/// The jobs waiting, oldest first, in runs/.queue.json: shared by every Mimic on this Mac (the
/// app, a dev build, `mimic` in Terminal), and kept across quits and crashes.
///
/// Every change happens under runs/.queue.lock, and so does every taking and releasing of the
/// job lock (runs/.job.lock). That one rule is what keeps a job from being lost: a runner that
/// finds the queue empty releases the job lock inside the same locked section, so a job added a
/// moment later always finds the job lock free and starts itself. A crash releases the job lock
/// outside that rule; the app looks again every few seconds and at launch.
public struct JobQueue: Sendable {
    public let runs: URL
    public init(runs: URL) { self.runs = runs }

    var file: URL { runs.appendingPathComponent(".queue.json") }
    var lockFile: URL { runs.appendingPathComponent(".queue.lock") }
    var pausedFile: URL { runs.appendingPathComponent(".queue.paused") }

    /// Paused (#89): no job starts, in any Mimic, until it's resumed; one already running
    /// finishes. A file of its own rather than a field in .queue.json, which Mimic 0.7.0 reads as
    /// a bare list: it would see an empty queue, and drop the pause the next time it wrote one.
    public var paused: Bool { FileManager.default.fileExists(atPath: pausedFile.path) }

    /// A snapshot, without the lock: the file is only ever replaced whole, so it reads complete.
    public func entries() -> [QueueEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([QueueEntry].self, from: data)) ?? []
    }

    /// Runs `body` holding the queue's lock, then saves the list if it changed. A fresh open
    /// each time: flock doesn't keep apart two threads sharing one open file, and does keep apart
    /// two opens, even in one process. O_CLOEXEC so a job's programs never inherit it.
    public func locked<T>(_ body: (inout [QueueEntry]) throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let fd = Self.openLock(lockFile)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(fd, LOCK_UN); close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var list = entries()
        let before = list
        let result = try body(&list)
        if list != before { try Self.encoder.encode(list).write(to: file, options: .atomic) }
        return result
    }

    /// A lock file, opened so a job's programs never inherit it: after a crash (which unlocks
    /// nothing) a program still running would otherwise hold the lock, and no Mimic could ever
    /// start another job.
    static func openLock(_ url: URL) -> Int32 { open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// The job running right now, in whichever Mimic holds the job lock: runs/.job.json, so another
/// Mimic (or `mimic queue`) can show it. It names the holder's pid and start time, so a record
/// left by a crash reads as nothing.
public struct SharedJob: Codable, Equatable, Sendable {
    public var name: String
    public var kind: JobKind
    public var step: Int
    public var started: Date
    public var stepStarted: Date
    var pid: Int32
    var pidStart: UInt64

    static func file(_ runs: URL) -> URL { runs.appendingPathComponent(".job.json") }

    static func write(_ s: JobStatus, runs: URL) {
        let me = getpid()
        guard let t = Leftover.startTime(me) else { return }
        let record = SharedJob(name: s.name, kind: s.kind, step: s.step, started: s.started,
                               stepStarted: s.stepStarted ?? s.started, pid: me, pidStart: t)
        try? JobQueue.encoder.encode(record).write(to: file(runs), options: .atomic)
    }

    static func clear(_ runs: URL) { try? FileManager.default.removeItem(at: file(runs)) }

    /// The running job, or nil when nothing runs (or the Mimic running it has gone).
    public static func read(_ runs: URL) -> SharedJob? {
        guard let data = try? Data(contentsOf: file(runs)),
              let r = try? JobQueue.decoder.decode(SharedJob.self, from: data),
              Leftover.startTime(r.pid) == r.pidStart else { return nil }
        return r
    }

    public var status: JobStatus {
        var s = JobStatus(name: name, kind: kind, step: step, started: started)
        s.stepStarted = stepStarted
        return s
    }
}
