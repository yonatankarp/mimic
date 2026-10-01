import Darwin
import Foundation
import OSLog

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
    /// Print prep warned about something other than a left-out part (the footprint).
    public var fragile = false
    /// What print prep said to tell the person, as it said it: a part it left out.
    public var notes: [String] = []
    /// When the step it's on began: time left is counted per step.
    public var stepStarted: Date?
    /// Step 1 is waiting for Draw Things to open.
    public var openingDrawThings = false
    /// A print prep that is an import's first (#96), not a resize: said as "Importing".
    public var importing = false
    public var succeeded: Bool { !running && !canceled && exit == 0 }
}

// In an extension, so the memberwise initialiser the tests use stays.
extension JobStatus {
    public init(name: String, kind: JobKind, step: Int, started: Date) {
        self.name = name; self.kind = kind; self.step = step; self.started = started
    }
}

/// Where the picture for a new mini comes from.
public enum PictureSource: Sendable {
    case image(URL)
    /// The text to draw from, and what the person typed when the AI helper improved it.
    case description(String, original: String? = nil)
}

/// Runs one job at a time: making a mini (three steps) or resizing one (print prep only). A job
/// asked for while another runs, here or in another Mimic, waits in the queue (`JobQueue`).
///
/// A job's programs run in their own session (GroupProcess) so Stop ends all of them. While a
/// runner is running jobs it holds the queue's job.lock, which every Mimic on this Mac (the app,
/// a dev build, `mimic` in a terminal) takes before starting one, and the holder runs the queue's
/// next job when one ends. job.pid beside it names the running program and its start time, so a job
/// orphaned by a crash can be stopped safely: by whoever next takes the lock, since only then is
/// it certain no live Mimic is running it.
public final class JobRunner: @unchecked Sendable {
    public let install: Install
    public let queue: JobQueue
    let tools: Tools
    let drawThings: DrawThings
    let trash: @Sendable (URL) throws -> Void
    let timings: Timings?
    let version: String

    private let lock = NSLock()
    private var current: JobStatus?
    private var process: GroupProcess?
    private var lockFD: Int32 = -1
    /// Held with the job lock: the Mac doesn't sleep on its own while jobs run (the screen may).
    private var awake: NSObjectProtocol?
    /// The Draw Things Mimic opened and hasn't quit yet: left open while the next job needs it.
    private var openedDrawThings: DrawThingsApp.Instance?
    /// Entered while this runner holds the job lock: waitUntilDone waits for it to go idle.
    private let idle = DispatchGroup()
    private var continues: @Sendable ([QueueEntry]) -> Bool = { _ in true }
    /// The running job was stopped by quitting: it goes back to the front of the queue, keeping
    /// what it made, instead of to the Trash.
    private var keepWork = false
    private var power: @Sendable () -> Bool = { false }
    public var onChange: (@Sendable (JobStatus) -> Void)?

    /// `timings`: where to record each finished job (nil records nothing, as in tests);
    /// `version`: this Mimic's, recorded with it.
    public init(install: Install, tools: Tools? = nil, drawThings: DrawThings = DrawThings(),
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                timings: Timings? = nil, version: String = "dev") {
        self.install = install
        self.queue = JobQueue(folder: install.queue)
        self.tools = tools ?? Tools.resolve(install)
        self.drawThings = drawThings
        self.trash = trash
        self.timings = timings
        self.version = version
    }

    public var status: JobStatus? { lock.withLock { current } }

    /// Whether to start the queue's next job when one ends, given what's waiting. The app always
    /// does; `mimic make` only until its own mini is made; quitting turns it off.
    public var keepGoing: @Sendable ([QueueEntry]) -> Bool {
        get { lock.withLock { continues } }
        set { lock.withLock { continues = newValue } }
    }

    /// The Mac is on battery with Don't start minis on battery on (`Power.holds`): the queue's
    /// next job waits. Asked each time one could start.
    public var heldForPower: @Sendable () -> Bool {
        get { lock.withLock { power } }
        set { lock.withLock { power = newValue } }
    }

    /// Why the queue's next job wouldn't start now, or nil.
    public func hold() -> QueueHold? {
        if queue.paused { return .paused }
        return heldForPower() ? .battery : nil
    }

    /// Pauses the queue for every Mimic on this Mac, or resumes it and, with `start`, starts its
    /// next job here if none is running. Pausing lets the running job finish: "Pause after this one".
    public func setPaused(_ paused: Bool, start: Bool = true) throws {
        Log.queue.notice("\(paused ? "Paused" : "Resumed", privacy: .public) the queue")
        try queue.locked { entries in
            let fm = FileManager.default
            if paused {
                guard fm.createFile(atPath: queue.pausedFile.path, contents: nil) else { throw POSIXError(.EIO) }
            } else {
                if fm.fileExists(atPath: queue.pausedFile.path) { try fm.removeItem(at: queue.pausedFile) }
                if start { pumpLocked(&entries) }
            }
        }
    }

    // MARK: Asking for a job

    /// Makes a new mini of `kind` with `model`, in `project` (nil: unsorted). Everything is
    /// checked before anything is written; then its folder, settings and picture are written and
    /// it joins the queue. Returns nil when it started at once, else how many jobs are ahead of it
    /// (the running one included). `versionOf` is the first of its versions, for Make Another Version.
    /// `cartoon` is only recorded: `model` and `restyle` are what make it one.
    /// `shown` is the name as typed ("Élodie"), shown for it; `name` is its folder's. New 3D Shape
    /// passes the picture step 1 made (`drawn`), so it isn't made again, and the 3D engine's own seed (`shapeSeed`).
    @discardableResult
    public func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes,
                     kind: MiniKind = .character, model: EngineModel, project: String? = nil, versionOf: String? = nil,
                     cartoon: Bool = false, shown: String? = nil, shapeSeed: Int? = nil, drawn: URL? = nil) throws -> Int? {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        if let project, !Gallery.projects(install.runs).contains(project) { throw RequestError.projectNotFound }
        _ = try sizes.flags()
        guard model.complete(in: install) else { throw RequestError.modelNotDownloaded(model.name) }
        if let drawn, !FileManager.default.isReadableFile(atPath: drawn.path) { throw RequestError.noPicture }
        var settings = MiniSettings()
        var tidied: Data?
        switch picture {
        case .image(let url):
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw RequestError.noPicture }
            guard let png = try? Engine.tidied(url) else { throw RequestError.unreadablePicture }
            tidied = png
            settings.source = .image
        case .description(let text, let original):
            settings.source = .desc; settings.desc = text; settings.descOriginal = original
        }
        settings.restyle = restyle; settings.seed = seed; settings.requested = sizes
        settings.kind = kind == .object ? .object : nil
        settings.model = model.id
        let fm = FileManager.default
        let folder = Gallery.newFolder(install.runs, name, project: project)
        _ = try Pipeline.plan(.generate, folder: folder, settings: settings, tools: tools)  // an empty description, say
        return try queue.locked { entries in
            try checkFree(name, entries)
            // A failed attempt's folder in the same place is made again; any other mini (or a
            // project) with this name, anywhere, keeps it.
            if let existing = Gallery.folder(install.runs, name),
               existing.standardizedFileURL != folder.standardizedFileURL || fm.fileExists(atPath: existing.appendingPathComponent("model.glb").path) {
                throw RequestError.nameTaken(name)
            }
            if Gallery.projects(install.runs).contains(where: { $0.lowercased() == name }) { throw RequestError.nameTaken(name) }
            let created = !fm.fileExists(atPath: folder.path)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                // settings.json first: it's what makes the folder a mini, so a failure after it
                // never leaves an empty folder that would read as a project.
                try MiniSettings.update(folder) { s in
                    s.source = settings.source; s.desc = settings.desc; s.descOriginal = settings.descOriginal; s.restyle = restyle; s.seed = seed; s.requested = sizes
                    s.kind = settings.kind  // always set: a failed attempt's folder may say otherwise
                    s.model = model.id
                    s.versionOf = versionOf
                    s.cartoon = cartoon ? true : nil  // always set, like kind
                    s.name(shown, folder: name)  // always set, like kind
                    s.shapeSeed = shapeSeed  // always set, as `kind` is
                    s.created = Date()  // a failed attempt's folder made again is a new mini
                }
                // A failed attempt's picture is from what it was asked for then: made again from
                // this one's, since the plan starts at the 3D step whenever it's there (#79).
                for f in ["source.png", "source__matted.png"] { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
                // Before it joins the queue, which may start it at once: then step 1 is skipped.
                if let drawn { try fm.copyItem(at: drawn, to: folder.appendingPathComponent("source.png")) }
                // Upright, a sensible size and PNG, tidied above (upload.img is its name from
                // before, when it was a copy of whatever was chosen).
                try tidied?.write(to: folder.appendingPathComponent("upload.img"), options: .atomic)
            } catch {
                if created { try? fm.removeItem(at: folder) }
                throw error
            }
            return enqueue(QueueEntry(name: name, job: .generate), &entries)
        }
    }

    /// Remakes the print file of an existing mini with new sizes (about a minute). Its sizes are
    /// written to its settings when it starts.
    @discardableResult
    public func resize(name: String, sizes: Sizes) throws -> Int? {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        _ = try sizes.flags()
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.glb").path) else { throw RequestError.noModelYet }
        var settings = MiniSettings.load(folder)
        settings.requested = sizes
        _ = try Pipeline.plan(.prep, folder: folder, settings: settings, tools: tools)
        return try queue.locked { entries in
            try checkFree(name, entries)
            return enqueue(QueueEntry(name: name, job: .prep, sizes: sizes), &entries)
        }
    }

    /// Runs a failed mini again, from what it saved: a resize if the 3D model exists, else all
    /// three steps.
    @discardableResult
    public func retry(name: String) throws -> Int? {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        let settings = MiniSettings.load(folder)
        // An imported model has nothing of its own to make again; Resize remakes its print file.
        if settings.isImported { throw RequestError.imported(name) }
        guard settings.requested != nil else { throw RequestError.nothingToRetry }
        let hasModel = FileManager.default.fileExists(atPath: folder.appendingPathComponent("model.glb").path)
        if !hasModel {
            // The same 3D model it was made with, and it has to be here: found out now, not minutes in.
            guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
            guard model.complete(in: install) else { throw RequestError.modelNotDownloaded(model.name) }
        }
        let kind: JobKind = hasModel ? .prep : .generate
        _ = try Pipeline.plan(kind, folder: folder, settings: settings, tools: tools)
        return try queue.locked { entries in
            try checkFree(name, entries)
            return enqueue(QueueEntry(name: name, job: kind), &entries)
        }
    }

    /// Takes a waiting job out of the queue. A new mini's folder goes to the Trash, as a stopped
    /// one's does, and so does an import's whose print file isn't made yet (#96). False when it
    /// isn't waiting (it may have just started).
    @discardableResult
    public func remove(_ name: String) throws -> Bool {
        let removed = try queue.locked { entries -> QueueEntry? in
            guard let i = entries.firstIndex(where: { $0.name == name }) else { return nil }
            return entries.remove(at: i)
        }
        guard let removed else { return false }
        if let folder = Gallery.folder(install.runs, name), removed.job == .generate || Self.importing(folder) { try? trash(folder) }
        return true
    }

    /// `remove`, for `mimic queue remove`: what it says, by the mini's name as shown. That's read
    /// first, since a new mini's folder, which keeps the name, goes to the Trash. Nil when it
    /// isn't waiting.
    public func removeSaying(_ name: String) throws -> String? {
        let shown = Mini.displayName(name, runs: install.runs)
        return try remove(name) ? "Took \(shown) out of the queue." : nil
    }

    /// Moves a waiting job `by` places, earlier (negative) or later. False when it isn't waiting.
    @discardableResult
    public func move(_ name: String, by offset: Int) throws -> Bool {
        try queue.locked { entries in
            guard let i = entries.firstIndex(where: { $0.name == name }) else { return false }
            let to = max(0, min(entries.count - 1, i + offset))
            entries.insert(entries.remove(at: i), at: to)
            return true
        }
    }

    /// Moves a waiting job to `place` in the queue (#72), under the queue's lock like every
    /// change, so two Mimics can't fight over the order. One mini at a time, and only waiting
    /// ones: the one being made is never stopped by a move, so the front is the next to start.
    /// False when it isn't waiting.
    @discardableResult
    public func move(_ name: String, to place: QueuePlace) throws -> Bool {
        try queue.locked { entries in
            guard let i = entries.firstIndex(where: { $0.name == name }) else { return false }
            let last = entries.count - 1
            let to: Int
            switch place {
            case .front: to = 0
            case .end: to = last
            case .position(let n): to = max(0, min(last, n - 1))
            }
            entries.insert(entries.remove(at: i), at: to)
            return true
        }
    }

    /// Starts the queue's next job if no Mimic is running one: at launch, and now and then after,
    /// since a Mimic that crashed or quit mid-queue left its jobs waiting. Also stops a job left
    /// running by a crash, which is only safe to do holding the lock.
    public func pump() { try? queue.locked { entries in pumpLocked(&entries) } }

    /// Stops a job left running by a Mimic that crashed, if no Mimic is running one now, and
    /// starts nothing (`mimic list`, `mimic queue`).
    public func cleanUpLeftovers() {
        try? queue.locked { _ in
            guard !holding, takeJobLock() else { return }
            releaseJobLock()
        }
    }

    /// The job running in any Mimic on this Mac: this runner's, else another's.
    public func running() -> JobStatus? {
        if let s = status, s.running { return s }
        return SharedJob.read(queue: install.queue)?.status
    }

    /// Stops the running job and everything it started. False when nothing is running. The
    /// queue carries on with its next job, unless `keepGoing` says otherwise.
    ///
    /// `keepingWork` is for quitting (#82): the job goes back to the front of the queue instead
    /// of to the Trash, and starts again at the first step it hadn't finished.
    @discardableResult
    public func cancel(keepingWork: Bool = false) -> Bool {
        let p: GroupProcess? = lock.withLock {
            guard current?.running == true else { return nil as GroupProcess? }
            current?.canceled = true
            keepWork = keepingWork
            return process
        }
        guard status?.canceled == true else { return false }
        Log.queue.notice("Stop asked for\(keepingWork ? ", to carry on next launch" : "", privacy: .public)")
        drawThings.cancel()
        if let p { DispatchQueue.global().async { p.terminateGroup() } }
        return true
    }

    /// Until this runner has no job left to run (for the command line and tests).
    public func waitUntilDone() { idle.wait() }

    // MARK: The queue (every function here runs holding the queue's lock)

    private var holding: Bool { lock.withLock { lockFD >= 0 } }

    func checkFree(_ name: String, _ entries: [QueueEntry]) throws {
        try refuseWhileMoving()
        if entries.contains(where: { $0.name == name }) { throw RequestError.queued(name) }
        if let r = running(), r.name == name { throw RequestError.busy(name, r.kind) }
    }

    func enqueue(_ entry: QueueEntry, _ entries: inout [QueueEntry]) -> Int? {
        entries.append(entry)
        pumpLocked(&entries)
        // Still waiting: one is running (ours, or another Mimic's), or the queue is held.
        guard let waiting = entries.firstIndex(where: { $0.name == entry.name }) else { return nil }
        return waiting + (hold() != nil && running() == nil ? 0 : 1)
    }

    private func pumpLocked(_ entries: inout [QueueEntry]) {
        if !holding {
            guard !entries.isEmpty, hold() == nil, takeJobLock() else { return }
        } else if status?.running == true {
            return  // it starts the next itself when it ends
        }
        startNext(&entries)
    }

    /// Starts the first waiting job that can start; releases the job lock when none can, or the
    /// queue is paused or waiting for power.
    private func startNext(_ entries: inout [QueueEntry]) {
        while !entries.isEmpty, hold() == nil {
            let entry = entries.removeFirst()
            do {
                try begin(entry)
                return
            } catch {
                // Checked when it was queued, so rare: its folder went, or its model was removed.
                var s = JobStatus(name: entry.name, kind: entry.job, step: entry.job == .prep ? 3 : 1, started: Date())
                s.running = false; s.exit = 1
                s.problem = (error as? RequestError)?.description ?? String(describing: error)
                lock.withLock { current = s }
                notify()
            }
        }
        releaseJobLock()
    }

    /// Only when no live Mimic holds it; then any job record left behind is an orphan's.
    private func takeJobLock() -> Bool {
        let fd = JobQueue.openLock(queue.jobLockFile)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { close(fd) }
            return false
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Making minis")
        lock.withLock { lockFD = fd; awake = activity }
        idle.enter()
        Leftover.stop(queue: install.queue)
        SharedJob.clear(queue: install.queue)
        return true
    }

    private func releaseJobLock() {
        let (fd, activity) = lock.withLock { defer { lockFD = -1; awake = nil }; return (lockFD, awake) }
        guard fd >= 0 else { return }
        quitDrawThings()
        SharedJob.clear(queue: install.queue)
        flock(fd, LOCK_UN); close(fd)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        idle.leave()
    }

    private func begin(_ entry: QueueEntry) throws {
        // By name, in whichever project: moves are refused while it waits, but Finder isn't.
        guard let folder = Gallery.folder(install.runs, entry.name) else { throw RequestError.notFound }
        if let sizes = entry.sizes { try MiniSettings.update(folder) { $0.requested = sizes } }
        let settings = MiniSettings.load(folder)
        let plan = try Pipeline.plan(entry.job, folder: folder, settings: settings, tools: tools)
        let log = folder.appendingPathComponent("\(entry.job.rawValue).job.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let now = Date()
        var s = JobStatus(name: entry.name, kind: entry.job, step: plan[0].number, started: now)
        s.stepStarted = now
        s.importing = entry.job == .prep && Self.importing(folder)
        lock.withLock { current = s; keepWork = false }
        SharedJob.write(s, queue: install.queue)
        notify()
        Log.queue.notice("Started \(entry.job.rawValue, privacy: .public) of \(entry.name, privacy: .public) at step \(plan[0].number)")
        Thread.detachNewThread { [self] in execute(plan, entry: entry, folder: folder, log: log, settings: settings) }
    }

    // MARK: Running

    private func execute(_ plan: [(number: Int, step: Step)], entry: QueueEntry, folder: URL, log: URL, settings: MiniSettings) {
        let kind = entry.job
        var code: Int32 = 0
        var finished: Set<Int> = []
        var problem: String?
        var took: [Int: TimeInterval] = [:]
        // prep.log is appended to on every run, so only this run's part says whether it's fragile.
        let prepLog = folder.appendingPathComponent("prep.log")
        let prepLogStart = (try? FileManager.default.attributesOfItem(atPath: prepLog.path)[.size] as? UInt64) ?? 0
        for (number, step) in plan {
            if status?.canceled == true { break }
            let began = Date()
            lock.withLock { current?.step = number; current?.stepStarted = began }
            if let s = status { SharedJob.write(s, queue: install.queue) }
            notify()
            append(log, "[\(number)/3] \(Self.label(number))\n")
            do {
                code = try run(step)
            } catch {
                code = 1
                problem = String(describing: error)
            }
            took[number] = Date().timeIntervalSince(began)
            if code != 0 { break }
            finished.insert(number)
        }
        let (canceled, kept) = lock.withLock { (current?.canceled == true, keepWork) }
        if canceled {
            code = code == 0 ? -15 : code
            if kept {
                // What the step it was on had written may be half written, and the next run
                // skips a step whose file is there: the picture, or the 3D shape.
                for (number, file) in [(1, "source.png"), (2, "model.glb")] where kind == .generate && plan.contains(where: { $0.number == number }) && !finished.contains(number) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
                }
            } else if kind == .generate || Self.importing(folder) {
                try? trash(folder)  // a half-made new mini (or import) is clutter, not a result
            }
        } else if code == 0, let requested = settings.requested {
            try? MiniSettings.update(folder) { $0.made = requested }  // "Now: …" shows only what a finished run made
        }
        let thisRun: String = {
            guard let h = try? FileHandle(forReadingFrom: prepLog) else { return "" }
            defer { try? h.close() }
            try? h.seek(toOffset: prepLogStart)
            return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        }()
        let warnings = (((try? String(contentsOf: log, encoding: .utf8)) ?? "") + "\n" + thisRun)
            .split(separator: "\n").filter { $0.contains("mini_prep: WARNING") }
        let said = [Prep.partWarning, Prep.standWarning]
        let fragile = warnings.contains { w in !said.contains { w.contains($0) } }
        var notes: [String] = []
        for w in warnings {
            guard let r = said.lazy.compactMap({ w.range(of: $0) }).first else { continue }
            let note = String(w[r.upperBound...])
            if !notes.contains(note) { notes.append(note) }  // the job log and prep.log can both carry it
        }
        // Print prep runs as its own program, so why it failed is only in its log.
        if code != 0, problem == nil, let r = thisRun.range(of: Prep.failure, options: .backwards) {
            problem = String(thisRun[r.upperBound...].prefix { $0 != "\n" })
        }
        // Kept with the mini, so its page says it after a relaunch too.
        if !canceled {
            let step = status?.step
            try? MiniSettings.update(folder) { s in
                if code == 0 {
                    s.notes = notes.isEmpty ? nil : notes; s.fragile = fragile ? true : nil
                    s.failed = nil; s.failedStep = nil
                } else {
                    s.failed = problem ?? "It stopped while \(Self.label(step ?? 2).lowercased())."; s.failedStep = step
                }
            }
        }
        let ended: JobStatus? = lock.withLock {
            current?.running = false
            current?.exit = code
            current?.problem = canceled ? nil : problem
            current?.fragile = fragile && code == 0
            current?.notes = code == 0 ? notes : []
            process = nil
            return current
        }
        let outcome = canceled ? "stopped" : code == 0 ? "finished" : "failed (exit \(code)): \(problem ?? "no reason given")"
        Log.queue.notice("\(kind.rawValue, privacy: .public) of \(entry.name, privacy: .public) \(outcome, privacy: .public)")
        if let ended { timings?.append([TimingRecord(ended, settings: settings, steps: took, version: version, machine: .current)]) }
        Leftover.clear(queue: install.queue)
        notify()
        // The next job, if any, starts before the lock is let go: no other Mimic can slip in.
        let going = keepGoing
        do {
            // Back at the front while this runner still holds the job lock, so no other Mimic can
            // start anything meanwhile; saved before the lock is let go (and waitUntilDone returns).
            if canceled && kept {
                try queue.locked { entries in
                    if !entries.contains(where: { $0.name == entry.name }) {
                        entries.insert(QueueEntry(name: entry.name, job: kind, added: entry.added), at: 0)
                    }
                }
            }
            try queue.locked { entries in if going(entries) { startNext(&entries) } else { releaseJobLock() } }
        } catch {
            if status?.running != true { releaseJobLock() }
        }
    }

    private func run(_ step: Step) throws -> Int32 {
        switch step {
        case let .copyPicture(from, to):
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
            return 0
        case let .drawCharacter(description, seed, to):
            try picture { try drawThings.draw(description: description, seed: seed) }.write(to: to, options: .atomic)
            return 0
        case let .sculptPicture(from, seed, to):
            try picture { try drawThings.sculpt(picture: from, seed: seed) }.write(to: to, options: .atomic)
            return 0
        case let .drawObject(description, seed, to):
            try picture { try drawThings.draw(description: description, seed: seed, kind: .object) }.write(to: to, options: .atomic)
            return 0
        case let .sculptObject(from, seed, to):
            try picture { try drawThings.sculpt(picture: from, seed: seed, kind: .object) }.write(to: to, options: .atomic)
            return 0
        case let .run(executable, arguments, directory, log):
            // At a lower priority (#89), so the Mac stays quick to use meanwhile. nice runs the
            // program in its own place (same pid, so Stop and the leftover record still find it),
            // and whatever it starts inherits it. Measured: on an idle Mac, work across every core
            // took as long at nice 10 as at 0.
            let p = try GroupProcess(executable: "/usr/bin/nice", arguments: ["-n", String(Self.nice), executable] + arguments,
                                     environment: tools.environment, workingDirectory: directory, log: log.path)
            let stopNow = lock.withLock { () -> Bool in process = p; return current?.canceled == true }
            Leftover.record(pid: p.pid, queue: install.queue)
            if stopNow { p.terminateGroup() }  // Stop pressed while the program was starting
            return p.wait()
        }
    }

    /// A picture from Draw Things, opening it first when needed and quitting it after if Mimic
    /// opened it, unless the next job needs it too.
    private func picture(_ draw: () throws -> Data) throws -> Data {
        let opened = try drawThings.openIfNeeded(canceled: { status?.canceled == true }, opening: {
            lock.withLock { current?.openingDrawThings = true }
            notify()
        })
        if status?.openingDrawThings == true {
            lock.withLock { current?.openingDrawThings = false }
            notify()
        }
        if let opened { lock.withLock { openedDrawThings = opened } }
        defer { if !nextNeedsDrawThings() { quitDrawThings() } }
        return try draw()
    }

    /// Whether the queue's next job, which this runner will run, asks Draw Things for a picture.
    private func nextNeedsDrawThings() -> Bool {
        let entries = queue.entries()
        guard let next = entries.first, next.job == .generate, keepGoing(entries), hold() == nil else { return false }
        guard let folder = Gallery.folder(install.runs, next.name) else { return false }
        let s = MiniSettings.load(folder)
        return s.source == .desc || s.restyle == true
    }

    private func quitDrawThings() {
        let opened: DrawThingsApp.Instance? = lock.withLock { defer { openedDrawThings = nil }; return openedDrawThings }
        if let opened, opened.alive() { opened.quit() }
    }

    private func append(_ log: URL, _ text: String) {
        guard let h = try? FileHandle(forWritingTo: log) else { return }
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    }

    private func notify() {
        if let s = status { onChange?(s) }
    }

    /// The nice value job programs run at.
    static let nice = 10

    public static func label(_ step: Int) -> String {
        ["", "Getting the picture ready", "Building the 3D shape", "Making the print-ready file"][max(0, min(3, step))]
    }
}

/// The record of a running job's program, so one orphaned by a crash can be stopped on the next
/// launch. It holds the pid *and* the program's start time: a pid alone may have been reused by
/// an unrelated program after a reboot, and stopping that would be far worse than a leftover.
public enum Leftover {
    /// job.pid in the queue's folder (`Install.queue`).
    static func file(queue: URL) -> URL { queue.appendingPathComponent("job.pid") }

    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func record(pid: pid_t, queue: URL) {
        guard let t = startTime(pid) else { return }
        try? "\(pid) \(t)".write(to: file(queue: queue), atomically: true, encoding: .utf8)
    }

    static func clear(queue: URL) { try? FileManager.default.removeItem(at: file(queue: queue)) }

    /// Whether a running program is on record (cheap: whether the file is there).
    public static func recorded(queue: URL) -> Bool { FileManager.default.fileExists(atPath: file(queue: queue).path) }

    /// Stops a job left running by a crashed Mimic. True when one was found and stopped.
    @discardableResult
    public static func stop(queue: URL) -> Bool {
        defer { clear(queue: queue) }
        guard let text = try? String(contentsOf: file(queue: queue), encoding: .utf8) else { return false }
        let parts = text.split(separator: " ").compactMap { UInt64($0) }
        guard parts.count == 2, let pid = pid_t(exactly: parts[0]), startTime(pid) == parts[1] else { return false }
        kill(-pid, SIGTERM)
        for _ in 0..<100 where kill(-pid, 0) == 0 { usleep(50_000) }
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        return true
    }
}
