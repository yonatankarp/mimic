import Darwin
import Foundation
import OSLog

/// The steps of a make, in order; a resize is the last one alone. Numbered as they're shown
/// ("Step 2 of 3") and saved.
public enum JobStep: Int, Codable, CaseIterable, Comparable, Sendable {
    case picture = 1, shape, print

    public var label: String {
        switch self {
        case .picture: "Getting the picture ready"
        case .shape: "Building the 3D shape"
        case .print: "Making the print-ready file"
        }
    }

    public static func < (a: JobStep, b: JobStep) -> Bool { a.rawValue < b.rawValue }
}

/// How a job is doing, or how it ended.
public enum JobOutcome: Sendable {
    /// `pictureReady`: a make stopped once its picture was made, for the person to check (#156).
    case running, finished, stopped, failed, pictureReady
}

/// Where a job is, for the progress window and `mimic make`.
public struct JobStatus: Equatable, Sendable {
    public var name: String
    public var kind: JobKind
    public var step: JobStep
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
    /// The mini's name as shown ("Élodie the Druid"), read as it starts: a stopped new mini's
    /// folder, which keeps that name, is in the Trash by the time it's named (#166).
    public var shown: String?
    /// It made the picture and stopped there, for the person to check it before the 3D shape (#156).
    public var pictureReady = false
    public var outcome: JobOutcome {
        running ? .running : canceled ? .stopped : exit != 0 ? .failed : pictureReady ? .pictureReady : .finished
    }
    public var succeeded: Bool { outcome == .finished }

    /// What to call the mini: its name as shown, or from its folder for a job from a Mimic
    /// before 0.9.0, which didn't say.
    public func displayName(runs: URL) -> String { shown ?? Mini.displayName(name, runs: runs) }
}

// In an extension, so the memberwise initialiser the tests use stays.
extension JobStatus {
    public init(name: String, kind: JobKind, step: JobStep, started: Date) {
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
    /// Held with the job lock: looks for `mimic stop` asking this runner to stop its job.
    private var stopWatch: DispatchSourceTimer?
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
    /// `version`: this Mimic's, recorded with it; `drawThings`: nil takes the one in `tools`, else the real one.
    public init(install: Install, tools: Tools? = nil, drawThings: DrawThings? = nil,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                timings: Timings? = nil, version: String = "dev") {
        self.install = install
        self.queue = JobQueue(folder: install.queue)
        self.tools = tools ?? Tools.resolve(install)
        self.drawThings = drawThings ?? self.tools.drawThings ?? DrawThings()
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

    /// The Mac is on battery with Start minis only when plugged in on (`Power.holds`): the queue's
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
    /// passes the picture step 1 made (`drawn`), so it isn't made again, and the 3D engine's own seed (`shapeSeed`);
    /// the pictures it made of `sides` beside it are kept too. `sides`: pictures of the back and
    /// sides besides `picture`, the front (#66), for a model that can use them. `fixes`: what to
    /// change in a picture, as typed, oldest first, the last one made by this mini's redraw
    /// (#156), which a fix always turns on; `fixUsed` is that last one as the AI helper rewrote it.
    /// `checkPicture`: stop once the picture is made, for the person to check it (`pictureToCheck`).
    @discardableResult
    public func make(name: String, picture: PictureSource, restyle: Bool, seed: Int, sizes: Sizes,
                     kind: MiniKind = .character, model: EngineModel, project: String? = nil, versionOf: String? = nil,
                     cartoon: Bool = false, shown: String? = nil, shapeSeed: Int? = nil, drawn: URL? = nil,
                     sides: [PictureSide: URL] = [:], fixes: [String] = [], fixUsed: String? = nil,
                     checkPicture: Bool = false) throws -> Int? {
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
            if !sides.isEmpty { throw RequestError.sidesNeedAPicture }
            settings.source = .desc; settings.desc = text; settings.descOriginal = original
        }
        let fixes = fixes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !fixes.isEmpty && settings.source == .desc { throw RequestError.fixNeedsAPicture }
        let used = fixUsed?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.fixes = fixes.isEmpty ? nil : fixes
        settings.fixUsed = fixes.isEmpty || used?.isEmpty != false || used == fixes.last ? nil : used
        let restyle = restyle || !fixes.isEmpty
        if !sides.isEmpty && !model.multiView { throw RequestError.oneSideOnly(model.name) }
        var tidiedSides: [(PictureSide, Data)] = []
        for side in PictureSide.allCases {
            guard let url = sides[side] else { continue }
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw RequestError.noPicture }
            guard let png = try? Engine.tidied(url) else { throw RequestError.unreadablePicture }
            tidiedSides.append((side, png))
        }
        settings.sides = tidiedSides.isEmpty ? nil : tidiedSides.map(\.0)
        settings.restyle = restyle; settings.seed = seed; settings.requested = sizes
        settings.kind = kind == .object ? .object : nil
        settings.model = model.id
        let fm = FileManager.default
        let folder = Gallery.newFolder(install.runs, name, project: project)
        _ = try Pipeline.plan(.generate, folder: folder, settings: settings, tools: tools)  // an empty description, say
        return try queue.locked { entries in
            try checkFree(name, entries)
            if Gallery.nameTaken(install.runs, name, project: project) { throw RequestError.nameTaken(name) }
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
                    s.sides = settings.sides  // always set, like kind
                    s.fixes = settings.fixes; s.fixUsed = settings.fixUsed  // always set, like kind
                    s.checkPicture = checkPicture ? true : nil  // always set, like kind
                }
                // A failed attempt's pictures are from what it was asked for then: made again from
                // this one's, since the plan starts at the 3D step whenever they're there (#79).
                for f in ["source.png", "source__matted.png"] + PictureSide.allCases.flatMap({
                    [$0.source, $0.source.replacingOccurrences(of: ".png", with: "__matted.png"), $0.upload]
                }) { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
                // Before it joins the queue, which may start it at once: then step 1 is skipped.
                if let drawn {
                    try fm.copyItem(at: drawn, to: folder.appendingPathComponent("source.png"))
                    for side in settings.sides ?? [] {
                        let made = drawn.deletingLastPathComponent().appendingPathComponent(side.source)
                        if fm.fileExists(atPath: made.path) { try fm.copyItem(at: made, to: folder.appendingPathComponent(side.source)) }
                    }
                }
                // Upright, a sensible size and PNG, tidied above (upload.img is its name from
                // before, when it was a copy of whatever was chosen).
                try tidied?.write(to: folder.appendingPathComponent("upload.img"), options: .atomic)
                for (side, png) in tidiedSides { try png.write(to: folder.appendingPathComponent(side.upload), options: .atomic) }
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
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(Mini.modelFile).path) else { throw RequestError.noModelYet }
        var settings = MiniSettings.load(folder)
        settings.requested = sizes
        _ = try Pipeline.plan(.prep, folder: folder, settings: settings, tools: tools)
        return try queue.locked { entries in
            try checkFree(name, entries)
            return enqueue(QueueEntry(name: name, job: .prep, sizes: sizes), &entries)
        }
    }

    /// Runs a failed mini again, from what it saved: a resize if the 3D model exists, else all
    /// three steps. It's Build Shape too, for a mini waiting for its picture to be checked
    /// (#156): its picture is made, so it carries on from the 3D shape.
    @discardableResult
    public func retry(name: String) throws -> Int? {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        let settings = MiniSettings.load(folder)
        // An imported model has nothing of its own to make again; Resize remakes its print file.
        if settings.isImported { throw RequestError.imported(name) }
        guard settings.requested != nil else { throw RequestError.nothingToRetry }
        let hasModel = FileManager.default.fileExists(atPath: folder.appendingPathComponent(Mini.modelFile).path)
        if !hasModel {
            // The same 3D model it was made with, and it has to be here: found out now, not minutes in.
            guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
            guard model.complete(in: install) else { throw RequestError.modelNotDownloaded(model.name) }
        }
        let kind: JobKind = hasModel ? .prep : .generate
        _ = try Pipeline.plan(kind, folder: folder, settings: settings, tools: tools)
        return try queue.locked { entries in
            try checkFree(name, entries)
            return enqueue(QueueEntry(name: name, job: kind, again: true), &entries)
        }
    }

    /// Try Again for a mini waiting for its picture to be checked (#156): its pictures are
    /// drawn again with a new number (`seed`, else a random one), since the same number draws
    /// the same picture, and it stops again once they're made. Stopped, it goes back to how it
    /// was, without them.
    @discardableResult
    public func redrawPicture(name: String, seed: Int? = nil) throws -> Int? {
        guard Rules.isValidName(name) else { throw RequestError.badName }
        guard let folder = Gallery.folder(install.runs, name) else { throw RequestError.notFound }
        let settings = MiniSettings.load(folder)
        guard Pipeline.pictureToCheck(folder, settings: settings) else { throw RequestError.noPictureToCheck(name) }
        guard let model = EngineDownload.model(settings.model) else { throw RequestError.unknownModel(settings.model ?? "") }
        guard model.complete(in: install) else { throw RequestError.modelNotDownloaded(model.name) }
        return try queue.locked { entries in
            try checkFree(name, entries)
            try MiniSettings.update(folder) { $0.seed = Self.newSeed(seed, not: settings.seed ?? 42) }
            for f in ["source.png", "source__matted.png"] + PictureSide.allCases.flatMap({
                [$0.source, $0.source.replacingOccurrences(of: ".png", with: "__matted.png")]
            }) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
            return enqueue(QueueEntry(name: name, job: .generate, again: true), &entries)
        }
    }

    /// Takes a waiting job out of the queue. A new mini's folder goes to the Trash, as a stopped
    /// one's does, and so does an import's whose print file isn't made yet (#96); a failed one
    /// waiting for Try Again stays as it was (#178). False when it
    /// isn't waiting (it may have just started). Trashed under the queue's lock, so a make with
    /// the same name (from another Mimic, say) can't take the folder over first.
    @discardableResult
    public func remove(_ name: String) throws -> Bool {
        try queue.locked { entries in
            guard let i = entries.firstIndex(where: { $0.name == name }) else { return false }
            let removed = entries.remove(at: i)
            if let folder = Gallery.folder(install.runs, name), removed.again != true, removed.job == .generate || Self.importing(folder) { try? trash(folder) }
            return true
        }
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
    /// of to the Trash, and starts again at the first step it hadn't finished. The first ask
    /// decides: a Stop then a quit while it ends still throws it away, and a quit then a Stop
    /// still keeps it (#171).
    @discardableResult
    public func cancel(keepingWork: Bool = false) -> Bool {
        let p: GroupProcess? = lock.withLock {
            guard current?.running == true else { return nil as GroupProcess? }
            if current?.canceled != true { keepWork = keepingWork }
            current?.canceled = true
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

    /// For `mimic make`: stops the running job, and the queue after it, when this program is
    /// told to end: Ctrl-C, its Terminal window closed, or `kill` (#174). The job's programs run
    /// in a session of their own, so they don't hear these. `heard` is told which it was first.
    /// Listens while what it returns is kept.
    public func stopOnSignals(_ heard: @escaping @Sendable (Int32) -> Void = { _ in }) -> [DispatchSourceSignal] {
        [SIGINT, SIGHUP, SIGTERM].map { sig in
            // Caught and let be, not ignored: an ignored signal stays ignored in the programs a
            // job starts, and SIGTERM couldn't stop them; a caught one is back to normal there.
            signal(sig) { _ in }
            let source = DispatchSource.makeSignalSource(signal: sig)
            source.setEventHandler { [self] in
                heard(sig)
                keepGoing = { _ in false }
                cancel()
            }
            source.resume()
            return source
        }
    }

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
                var s = JobStatus(name: entry.name, kind: entry.job, step: entry.job == .prep ? .print : .picture, started: Date())
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
        let watch = DispatchSource.makeTimerSource(queue: .global())
        watch.schedule(deadline: .now() + 0.5, repeating: 0.5)
        watch.setEventHandler { [weak self] in self?.answerStopRequest() }
        watch.resume()
        lock.withLock { lockFD = fd; awake = activity; stopWatch = watch }
        idle.enter()
        Leftover.stop(queue: install.queue)
        SharedJob.clear(queue: install.queue)
        return true
    }

    private func releaseJobLock() {
        let (fd, activity, watch) = lock.withLock { defer { lockFD = -1; awake = nil; stopWatch = nil }; return (lockFD, awake, stopWatch) }
        guard fd >= 0 else { return }
        watch?.cancel()
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
        s.shown = settings.shownName(folder: entry.name)
        // Before the job can be stopped, so a Stop while step 1 starts isn't forgotten (#170).
        drawThings.reset()
        lock.withLock { current = s; keepWork = false }
        SharedJob.write(s, queue: install.queue)
        notify()
        Log.queue.notice("Started \(entry.job.rawValue, privacy: .public) of \(entry.name, privacy: .public) at step \(plan[0].number.rawValue)")
        Thread.detachNewThread { [self] in execute(plan, entry: entry, folder: folder, log: log, settings: settings) }
    }

    // MARK: Running

    /// What running a job's plan came to.
    private struct PlanRun {
        var code: Int32 = 0
        /// Runs of the plan finished.
        var done = 0
        var problem: String?
        var took: [JobStep: TimeInterval] = [:]
    }

    /// How a job ended, once its folder is settled: what `finish` reports and records.
    private struct Ending {
        var canceled: Bool
        var kept: Bool
        var fragile: Bool
        var notes: [String]
        /// It made its picture and stopped, for the person to check it (#156).
        var pictureReady = false
    }

    private func execute(_ plan: [(number: JobStep, step: Step)], entry: QueueEntry, folder: URL, log: URL, settings: MiniSettings) {
        // What print prep reports, this run's only: an earlier run's must not follow the mini around.
        let reportFile = folder.appendingPathComponent("prep-result.json")
        try? FileManager.default.removeItem(at: reportFile)
        var ran = runPlan(plan, log: log)
        let ending = settle(&ran, plan: plan, entry: entry, folder: folder, reportFile: reportFile, settings: settings)
        finish(ran, ending, entry: entry, settings: settings)
    }

    /// Runs the plan's steps in turn, until one fails or the job is stopped.
    private func runPlan(_ plan: [(number: JobStep, step: Step)], log: URL) -> PlanRun {
        var ran = PlanRun()
        var previous = plan.first?.number  // begin() started its clock
        for (number, step) in plan {
            if status?.canceled == true { break }
            let began = Date()
            // Step 1 is one run per picture, timed as one step: its time left mustn't start over.
            lock.withLock { current?.step = number; if number != previous { current?.stepStarted = began } }
            previous = number
            if let s = status { SharedJob.write(s, queue: install.queue) }
            notify()
            append(log, "[\(number.rawValue)/3] \(number.label)\n")
            do {
                ran.code = try run(step)
            } catch {
                ran.code = 1
                ran.problem = String(describing: error)
            }
            ran.took[number, default: 0] += Date().timeIntervalSince(began)  // step 1 is one run per picture
            if ran.code != 0 { break }
            ran.done += 1
        }
        return ran
    }

    /// The mini's folder after its job: a stopped job's work cleared away (or kept, when it was
    /// stopped by quitting or was a Try Again), a finished one's sizes recorded, and how it went
    /// kept with the mini.
    private func settle(_ ran: inout PlanRun, plan: [(number: JobStep, step: Step)], entry: QueueEntry, folder: URL,
                        reportFile: URL, settings: MiniSettings) -> Ending {
        let kind = entry.job
        let (canceled, kept) = lock.withLock { (current?.canceled == true, keepWork) }
        if canceled {
            ran.code = ran.code == 0 ? -15 : ran.code
            // A stopped Try Again goes back to how it failed, with what it had before (#178).
            if kept || entry.again == true {
                // What the step it was on had written may be half written, and the next run
                // skips a step whose file is there: a picture, or the 3D shape. Step 1 is one run
                // per picture, so the pictures it had finished are kept.
                for (number, step) in plan.dropFirst(ran.done) where kind == .generate {
                    if let file = number == .shape ? folder.appendingPathComponent(Mini.modelFile) : step.makes { try? FileManager.default.removeItem(at: file) }
                }
            } else if kind == .generate || Self.importing(folder) {
                try? trash(folder)  // a half-made new mini (or import) is clutter, not a result
            }
        }
        // A make that stops for its picture to be checked has only made the picture (#156).
        let pictureReady = !canceled && ran.code == 0 && plan.last?.number == .picture
        if !canceled, !pictureReady, ran.code == 0, let requested = settings.requested {
            try? MiniSettings.update(folder) { $0.made = requested }  // "Now: …" shows only what a finished run made
        }
        let report = PrepReport.read(folder) ?? PrepReport()
        try? FileManager.default.removeItem(at: reportFile)
        let fragile = report.fragile, notes = report.notes
        // Print prep runs as its own program, so why it failed is only in its report.
        if ran.code != 0, ran.problem == nil { ran.problem = report.failure.map { String($0.prefix { $0 != "\n" }) } }
        // Kept with the mini, so its page says it after a relaunch too.
        if !canceled {
            let step = status?.step
            let code = ran.code, problem = ran.problem
            try? MiniSettings.update(folder) { s in
                if code == 0 {
                    if !pictureReady { s.notes = notes.isEmpty ? nil : notes; s.fragile = fragile ? true : nil }
                    s.failed = nil; s.failedStep = nil
                } else {
                    s.failed = problem ?? "It stopped while \((step ?? .shape).label.lowercased())."; s.failedStep = step?.rawValue
                }
            }
        }
        return Ending(canceled: canceled, kept: kept, fragile: fragile, notes: notes, pictureReady: pictureReady)
    }

    /// Ends the job: its status, its line in the log and its time, then the queue's next job, or
    /// a stopped-by-quitting one back at the front.
    private func finish(_ ran: PlanRun, _ ending: Ending, entry: QueueEntry, settings: MiniSettings) {
        let kind = entry.job, code = ran.code, problem = ran.problem
        let canceled = ending.canceled, kept = ending.kept, fragile = ending.fragile, notes = ending.notes
        let ended: JobStatus? = lock.withLock {
            current?.running = false
            current?.exit = code
            current?.problem = canceled ? nil : problem
            current?.fragile = fragile && code == 0
            current?.notes = code == 0 ? notes : []
            current?.pictureReady = ending.pictureReady
            process = nil
            return current
        }
        let outcome = canceled ? "stopped" : code != 0 ? "failed (exit \(code)): \(problem ?? "no reason given")"
            : ending.pictureReady ? "stopped for its picture to be checked" : "finished"
        Log.queue.notice("\(kind.rawValue, privacy: .public) of \(entry.name, privacy: .public) \(outcome, privacy: .public)")
        // Not one that stopped for its picture to be checked: it would count as a whole make.
        if let ended, !ending.pictureReady {
            timings?.append([TimingRecord(ended, settings: settings, steps: ran.took, version: version, machine: .current)])
        }
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
                        entries.insert(QueueEntry(name: entry.name, job: kind, added: entry.added, again: entry.again), at: 0)
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
        case let .sculptPicture(from, seed, to, change):
            try picture { try drawThings.sculpt(picture: from, seed: seed, change: change) }.write(to: to, options: .atomic)
            return 0
        case let .drawObject(description, seed, to):
            try picture { try drawThings.draw(description: description, seed: seed, kind: .object) }.write(to: to, options: .atomic)
            return 0
        case let .sculptObject(from, seed, to, change):
            try picture { try drawThings.sculpt(picture: from, seed: seed, kind: .object, change: change) }.write(to: to, options: .atomic)
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
            let code = p.wait()
            // Stopped, what it started may outlive it, holding memory and writing into the mini's
            // folder: the job ends, and its record goes, only once they have too (#174).
            if status?.canceled == true { Self.waitForGroup(p.pid) }
            lock.withLock { if process === p { process = nil } }  // a Stop between steps has nothing to signal
            return code
        }
    }

    /// Until every program in the group `pid` led has ended, ending whatever is left after
    /// `grace` seconds, as `GroupProcess.terminateGroup` does from the Stop that ended the leader.
    static func waitForGroup(_ pid: pid_t, grace: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(grace)
        while kill(-pid, 0) == 0, Date() < deadline { usleep(50_000) }
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        for _ in 0..<40 where kill(-pid, 0) == 0 { usleep(50_000) }
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
        return s.source == .desc || s.restyle == true || s.change != nil
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
