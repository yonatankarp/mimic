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
    /// Try Again of a mini that was there before this job (#178): stopped or taken out of the
    /// queue, it goes back to how it was, failed, instead of to the Trash as a new one does.
    public var again: Bool?
    public var id: String { name }

    public init(name: String, job: JobKind, added: Date = Date(), sizes: Sizes? = nil, again: Bool? = nil) {
        self.name = name; self.job = job; self.added = added; self.sizes = sizes; self.again = again
    }

    /// What taking it out of the queue does to the mini, as `JobRunner.remove` does it.
    public func takeOutSays(importing: Bool) -> String {
        job == .prep && !importing ? "It keeps its current size."
            : again == true ? "It stays, so you can try again later."
            : job == .generate ? "It hasn't been made yet, so its picture and settings go to the Trash, where you can get them back."
            : "It hasn't been made yet, so it goes to the Trash, where you can get it back."
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

/// The jobs waiting, oldest first, in queue.json in the queue's folder (`Install.queue`, on this
/// Mac): shared by every Mimic on this Mac using the same minis folder (the app, a dev build,
/// `mimic` in Terminal), and kept across quits and crashes.
///
/// Every change happens under queue.lock, and so does every taking and releasing of the job lock
/// (job.lock). That one rule is what keeps a job from being lost: a runner that finds the queue
/// empty releases the job lock inside the same locked section, so a job added a moment later
/// always finds the job lock free and starts itself. A crash releases the job lock outside that
/// rule; the app looks again every few seconds and at launch.
public struct JobQueue: Sendable {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    var file: URL { folder.appendingPathComponent("queue.json") }
    var lockFile: URL { folder.appendingPathComponent("queue.lock") }
    var pausedFile: URL { folder.appendingPathComponent("paused") }
    var jobLockFile: URL { folder.appendingPathComponent("job.lock") }
    /// `mimic stop` asking whichever Mimic runs the job named in it to stop it (#129).
    var stopFile: URL { folder.appendingPathComponent("job.stop") }

    /// Paused (#89): no job starts, in any Mimic, until it's resumed; one already running
    /// finishes. A file of its own rather than a field in queue.json, which Mimic 0.7.0 read as a
    /// bare list.
    public var paused: Bool { FileManager.default.fileExists(atPath: pausedFile.path) }

    /// The minis are moving to another folder (`JobRunner.changeMinisFolder`): nothing may be
    /// made, resized or moved in this one meanwhile. The mover's pid and start time, so a move
    /// cut short by a crash reads as over.
    var movingFile: URL { folder.appendingPathComponent("moving") }
    public var moving: Bool {
        guard let text = try? String(contentsOf: movingFile, encoding: .utf8) else { return false }
        let parts = text.split(separator: " ").compactMap { UInt64($0) }
        guard parts.count == 2, let pid = pid_t(exactly: parts[0]) else { return false }
        return Leftover.startTime(pid) == parts[1]
    }

    func markMoving() throws {
        let me = getpid()
        guard let t = Leftover.startTime(me) else { throw POSIXError(.ESRCH) }
        try "\(me) \(t)".write(to: movingFile, atomically: true, encoding: .utf8)
    }

    func clearMoving() { try? FileManager.default.removeItem(at: movingFile) }

    /// A snapshot, without the lock: the file is only ever replaced whole, so it reads complete.
    public func entries() -> [QueueEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([QueueEntry].self, from: data)) ?? []
    }

    /// Runs `body` holding the queue's lock, then saves the list if it changed. A fresh open
    /// each time: flock doesn't keep apart two threads sharing one open file, and does keep apart
    /// two opens, even in one process. O_CLOEXEC so a job's programs never inherit it.
    public func locked<T>(_ body: (inout [QueueEntry]) throws -> T) throws -> T {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

/// The job running right now, in whichever Mimic holds the job lock: job.json in the queue's
/// folder, so another Mimic (or `mimic queue`) can show it. It names the holder's pid and start
/// time, so a record left by a crash reads as nothing.
public struct SharedJob: Codable, Equatable, Sendable {
    public var name: String
    public var kind: JobKind
    public var step: JobStep
    public var started: Date
    public var stepStarted: Date
    var pid: Int32
    var pidStart: UInt64
    /// `JobStatus.shown`, so `mimic stop` names it as shown once it's in the Trash.
    public var shown: String?
    /// `JobStatus.again`, so a Stop from elsewhere says a Try Again is kept.
    public var again: Bool?

    static func file(queue: URL) -> URL { queue.appendingPathComponent("job.json") }

    static func write(_ s: JobStatus, queue: URL) {
        let me = getpid()
        guard let t = Leftover.startTime(me) else { return }
        let record = SharedJob(name: s.name, kind: s.kind, step: s.step, started: s.started,
                               stepStarted: s.stepStarted ?? s.started, pid: me, pidStart: t, shown: s.shown, again: s.again)
        try? JobQueue.encoder.encode(record).write(to: file(queue: queue), options: .atomic)
    }

    static func clear(queue: URL) { try? FileManager.default.removeItem(at: file(queue: queue)) }

    /// The running job, or nil when nothing runs (or the Mimic running it has gone).
    public static func read(queue: URL) -> SharedJob? {
        guard let data = try? Data(contentsOf: file(queue: queue)),
              let r = try? JobQueue.decoder.decode(SharedJob.self, from: data),
              Leftover.startTime(r.pid) == r.pidStart else { return nil }
        return r
    }

    public var status: JobStatus {
        var s = JobStatus(name: name, kind: kind, step: step, started: started)
        s.stepStarted = stepStarted
        s.shown = shown
        s.again = again == true
        return s
    }
}
