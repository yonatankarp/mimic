import Darwin
import Foundation
import IOKit

/// This Mac, as far as job times go: a history recorded on another Mac (moved over with
/// Migration Assistant, say) says nothing about this one.
public struct Machine: Codable, Equatable, Sendable {
    public var chip: String
    public var memoryGB: Int
    public var gpuCores: Int?

    public init(chip: String, memoryGB: Int, gpuCores: Int? = nil) {
        self.chip = chip; self.memoryGB = memoryGB; self.gpuCores = gpuCores
    }

    public static let current: Machine = {
        func text(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var mem: UInt64 = 0, size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        // The GPU's core count is in the IO registry on Apple silicon; absent elsewhere.
        let gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        defer { if gpu != 0 { IOObjectRelease(gpu) } }
        let cores = gpu == 0 ? nil : IORegistryEntryCreateCFProperty(gpu, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        return Machine(chip: text("machdep.cpu.brand_string"), memoryGB: Int(mem >> 30), gpuCores: cores)
    }()

    func same(_ o: Machine) -> Bool { chip == o.chip && memoryGB == o.memoryGB }
}

/// One finished job, as a line of timings.jsonl.
public struct TimingRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case finished, failed, stopped }
    public var date: Date
    public var version: String
    public var machine: Machine
    /// "make" or "resize".
    public var job: String
    public var mini: MiniKind
    public var model: String
    /// "picture" or "description"; nil for a resize.
    public var source: String?
    public var restyled: Bool?
    public var height: Double?
    public var nozzle: String?
    public var base: Double?
    /// Seconds each step took, by step number ("1", "2", "3").
    public var steps: [String: Double]
    public var total: Double
    public var outcome: Outcome
    /// Worked out afterwards from a mini's files, not timed as it ran.
    public var imported: Bool?
    /// How many pictures a make started from (#66); nil is one.
    public var pictures: Int? = nil

    public var jobKind: JobKind { job == "resize" ? .prep : .generate }
    /// Step 1 asked Draw Things for a picture, rather than copying one.
    var drawn: Bool { source == "description" || restyled == true }
}

/// What a job to be estimated is: the things its time depends on.
public struct JobShape: Equatable, Sendable {
    public var job: JobKind
    public var model: String
    public var drawn: Bool
    public var nozzle: String?
    public var height: Double?
    /// The front picture and those of the back and sides (#66): step 1 makes each.
    public var pictures: Int

    public init(job: JobKind, model: String, drawn: Bool, nozzle: String? = nil, height: Double? = nil, pictures: Int = 1) {
        self.job = job; self.model = model; self.drawn = drawn; self.nozzle = nozzle; self.height = height; self.pictures = pictures
    }

    /// The job `kind` for the mini whose settings are `settings`; `sizes` for a resize not yet
    /// written to them.
    public init(_ kind: JobKind, settings: MiniSettings, sizes: Sizes? = nil) {
        let s = sizes ?? settings.requested
        self.init(job: kind, model: EngineDownload.model(settings.model)?.id ?? settings.model ?? EngineDownload.standard.id,
                  drawn: settings.source == .desc || settings.restyle == true,
                  nozzle: s?.nozzle ?? "0.4", height: s?.height.flatMap(Double.init), pictures: settings.pictures)
    }
}

/// How long each step of a job should take on this Mac.
public struct Estimate: Equatable, Sendable {
    public var steps: [JobStep: TimeInterval]
    /// From this Mac's own history, rather than Mimic's fixed figures.
    public var learned: Bool
    public var total: TimeInterval { steps.values.reduce(0, +) }

    public init(steps: [JobStep: TimeInterval], learned: Bool) { self.steps = steps; self.learned = learned }

    /// Seconds left: the rest of the step it's in (nothing once past its estimate) and every
    /// step after it.
    public func left(_ s: JobStatus, now: Date = Date()) -> TimeInterval {
        guard s.running else { return 0 }
        let inStep = now.timeIntervalSince(s.stepStarted ?? s.started)
        return steps.filter { $0.key > s.step }.values.reduce(0, +) + max(0, (steps[s.step] ?? 0) - inStep)
    }

    /// How far along, by the estimate: whole steps done, plus the time into this one.
    public func fraction(_ s: JobStatus, now: Date = Date()) -> Double {
        guard total > 0 else { return 0 }
        let inStep = now.timeIntervalSince(s.stepStarted ?? s.started)
        let done = steps.filter { $0.key < s.step }.values.reduce(0, +) + min(inStep, steps[s.step] ?? 0)
        return done / total
    }
}

public enum Estimator {
    /// Fewer similar finished jobs than this and the fixed figures are used.
    public static let minimum = 3
    /// Only the most recent similar jobs count: a newer Mimic or engine may be faster.
    static let recent = 15
    /// The 3D step from several pictures against one (#66): TRELLIS.2's multi-image mode runs
    /// every flow at 12 steps, ignoring PIXAL3D_STEPS=8. Three pictures took 615 s on an M2 Max
    /// where one takes 222 (the median of its last ten).
    static let multiViewShape = 2.8

    /// Picture from Draw Things, or copied; print prep (Swift: 6–14 s measured, so this errs
    /// slow, as "about a minute" always did). The 3D step is the model's whole-mini time
    /// (EngineModel.minutes, measured on an M2 Max) less the other two.
    static func fixed(_ shape: JobShape) -> Estimate {
        let prep = 45.0
        if shape.job == .prep { return Estimate(steps: [.print: prep], learned: false) }
        let whole = Double((EngineDownload.model(shape.model)?.minutes ?? 8) * 60)
        let shapeStep = whole - 60 - prep
        return Estimate(steps: [.picture: (shape.drawn ? 60 : 5) * Double(shape.pictures),
                                .shape: shape.pictures > 1 ? shapeStep * multiViewShape : shapeStep, .print: prep], learned: false)
    }

    /// Each step is the median of that step in the most recent similar jobs that finished on
    /// this Mac, or the fixed figure when there are too few:
    /// - the picture: jobs whose picture came the same way (Draw Things or a copy);
    /// - the 3D shape: makes with the same 3D model;
    /// - the print file: makes and resizes alike, for the same nozzle at a height within 30%,
    ///   else any on this Mac (print prep's time grows with the size and a finer nozzle).
    /// Failed and stopped jobs never count: they end early, or late, for reasons of their own.
    public static func estimate(_ shape: JobShape, history: [TimingRecord], machine: Machine = .current) -> Estimate {
        let usable = history.filter { $0.outcome == .finished && $0.machine.same(machine) }
        var e = fixed(shape)
        var learned = false
        /// `each`: step 1 as the time per picture, since a make from four pictures makes four.
        func median(_ step: JobStep, _ records: [TimingRecord], each: Bool = false) -> Double? {
            let values = records.reversed().compactMap { r in r.steps[String(step.rawValue)].map { each ? $0 / Double(r.pictures ?? 1) : $0 } }
                .prefix(recent).sorted()
            guard values.count >= minimum else { return nil }
            let mid = values.count / 2
            return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
        }
        if shape.job == .generate {
            let makes = usable.filter { $0.jobKind == .generate }
            if let m = median(.picture, makes.filter { $0.drawn == shape.drawn }, each: true) { e.steps[.picture] = m * Double(shape.pictures) }
            // The 3D step from several pictures runs the slower way (`multiViewShape`): those
            // learn from each other, not from one-picture makes.
            if let m = median(.shape, makes.filter { $0.model == shape.model && ($0.pictures ?? 1 > 1) == (shape.pictures > 1) }) {
                e.steps[.shape] = m; learned = true
            } else if shape.pictures > 1, let m = median(.shape, makes.filter { $0.model == shape.model }) {
                e.steps[.shape] = m * multiViewShape; learned = true
            }
        }
        let similar = usable.filter { r in
            guard r.nozzle == shape.nozzle else { return false }
            guard let a = r.height, let b = shape.height, b > 0 else { return r.height == shape.height }
            return abs(a - b) / b <= 0.3
        }
        if let m = median(.print, similar) ?? median(.print, usable) {
            e.steps[.print] = m
            if shape.job == .prep { learned = true }
        }
        e.learned = learned
        return e
    }
}

/// Every job this Mac has finished, one JSON line each, in timings.jsonl: kept on this Mac only
/// (never uploaded, never in the minis folder, so sharing that shares none of it), capped so it
/// stays small.
public struct Timings: Sendable {
    public let url: URL
    public static let cap = 2000

    public init(url: URL) { self.url = url }

    /// ~/Library/Application Support/Mimic/timings.jsonl. `MIMIC_TIMINGS` names another file,
    /// and a development Mimic (`MIMIC_HOME`, `MIMIC_FAKE_HOME`) keeps its own, so trying things
    /// never mixes pretend jobs into the real history.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Timings {
        if let path = environment["MIMIC_TIMINGS"] { return Timings(url: URL(fileURLWithPath: path)) }
        if let root = Install.folder(environment["MIMIC_HOME"]) { return Timings(url: root.appendingPathComponent("timings.jsonl")) }
        let base = environment["MIMIC_FAKE_HOME"].map { URL(fileURLWithPath: $0) } ?? home
        return Timings(url: base.appendingPathComponent("Library/Application Support/Mimic/timings.jsonl"))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()

    public func load() -> [TimingRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JobQueue.decoder.decode(TimingRecord.self, from: Data($0.utf8)) }
    }

    /// The lock beside the history: the history itself is replaced whole, so a lock on it would
    /// be let go of with the file it was on.
    var lockFile: URL { url.appendingPathExtension("lock") }

    /// Runs `body` holding the lock, so two Mimics finishing together both get their line in.
    private func locked(_ body: () -> Void) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = JobQueue.openLock(lockFile)
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); close(fd) }
        while flock(fd, LOCK_EX) != 0 { guard errno == EINTR else { return } }
        body()
    }

    /// Adds one, dropping the oldest past the cap. Written beside the history and then put in
    /// its place, so a crash halfway leaves the history as it was.
    public func append(_ records: [TimingRecord]) {
        locked { add(records) }
    }

    /// `append`, for one already holding the lock.
    private func add(_ records: [TimingRecord]) {
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var lines = text.split(separator: "\n").map(String.init)
        lines += records.compactMap { (try? Self.encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        let kept = lines.suffix(Self.cap)
        try? Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: url, options: .atomic)
    }

    /// Forgets every job (Settings → Time estimates → Clear). The empty file stays, so the old
    /// minis aren't imported again.
    public func clear() {
        locked { try? Data().write(to: url, options: .atomic) }
    }

    /// The first time this Mimic runs, the minis already made seed the history (`imported`).
    /// The file existing at all is the marker, so this happens once: checked and written under
    /// one lock, so the app and `mimic` starting together don't both seed (#333).
    public func seedIfNeeded(runs: URL, machine: Machine = .current) {
        locked {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            add(Self.importPast(runs: runs, machine: machine))
        }
    }

    /// Past makes worked out from their files, when those can be trusted. The job log is created
    /// as the job starts and last written as step 3 starts; pixal3d.log is created as step 2
    /// starts; the print file is written as step 3 ends. A mini is skipped unless its log is
    /// exactly this Mimic's three step lines, pixal3d.log is newer than the job log (Try Again
    /// adds to an old one), no resize came after (it rewrote the print file), and the times run
    /// in order to a plausible whole.
    public static func importPast(runs: URL, machine: Machine = .current) -> [TimingRecord] {
        let fm = FileManager.default
        func times(_ u: URL) -> (born: Date, changed: Date)? {
            guard let a = try? fm.attributesOfItem(atPath: u.path),
                  let b = a[.creationDate] as? Date, let m = a[.modificationDate] as? Date else { return nil }
            return (b, m)
        }
        let expected = JobStep.allCases.map { "[\($0.rawValue)/3] \($0.label)" }
        var out: [TimingRecord] = []
        for mini in Gallery.list(runs) {
            let f = mini.folder
            guard let log = times(f.appendingPathComponent("generate.job.log")),
                  let text = try? String(contentsOf: f.appendingPathComponent("generate.job.log"), encoding: .utf8),
                  text.split(separator: "\n").map(String.init) == expected,
                  let engine = times(f.appendingPathComponent("pixal3d.log")),
                  let stl = times(f.appendingPathComponent("\(mini.name).stl")) else { continue }
            if let resize = times(f.appendingPathComponent("prep.job.log")), resize.changed >= log.born { continue }
            let start = log.born, step2 = engine.born, step3 = log.changed, end = stl.changed
            guard start <= step2, step2 < step3, step3 <= end else { continue }
            let total = end.timeIntervalSince(start)
            guard (60...3 * 3600).contains(total) else { continue }
            let s = MiniSettings.load(f)
            out.append(TimingRecord(
                date: end, version: "imported", machine: machine, job: "make", mini: s.kind ?? .character,
                model: EngineDownload.model(s.model)?.id ?? s.model ?? EngineDownload.standard.id,
                source: s.source == .desc ? "description" : "picture", restyled: s.restyle ?? false,
                height: s.requested?.height.flatMap(Double.init), nozzle: s.requested?.nozzle ?? "0.4",
                base: s.requested?.base.flatMap(Double.init),
                steps: ["1": step2.timeIntervalSince(start), "2": step3.timeIntervalSince(step2), "3": end.timeIntervalSince(step3)],
                total: total, outcome: .finished, imported: true))
        }
        return out.sorted { $0.date < $1.date }
    }
}

extension TimingRecord {
    /// The record of a job that just ended.
    init(_ s: JobStatus, settings: MiniSettings, steps: [JobStep: TimeInterval], version: String, machine: Machine) {
        let sizes = settings.requested
        self.init(date: Date(), version: version, machine: machine, job: s.kind == .prep ? "resize" : "make",
                  mini: settings.kind ?? .character,
                  model: EngineDownload.model(settings.model)?.id ?? settings.model ?? EngineDownload.standard.id,
                  source: s.kind == .prep ? nil : settings.source == .desc ? "description" : "picture",
                  restyled: s.kind == .prep ? nil : settings.restyle ?? false,
                  height: sizes?.height.flatMap(Double.init), nozzle: sizes?.nozzle ?? "0.4", base: sizes?.base.flatMap(Double.init),
                  steps: Dictionary(uniqueKeysWithValues: steps.map { (String($0.key.rawValue), $0.value) }),
                  total: steps.values.reduce(0, +),
                  outcome: s.canceled ? .stopped : s.exit == 0 ? .finished : .failed, imported: nil,
                  pictures: s.kind == .prep || settings.pictures == 1 ? nil : settings.pictures)
    }
}

extension JobRunner {
    /// How long the job `kind` on the mini `name` should take here; `sizes` for a resize still
    /// waiting to write them. Its settings come from `minis` (the gallery as last read) when it's
    /// there, so a progress tick doesn't read its file; else from its folder. A make still
    /// `waiting` takes nothing for the steps it will skip (`Pipeline.skipped`). Not the running
    /// one's: a make writes its picture as it goes, and its progress would jump back.
    public func estimate(_ name: String, _ kind: JobKind, sizes: Sizes? = nil, history: [TimingRecord], minis: [Mini] = [],
                         waiting: Bool = false) -> Estimate {
        let mini = minis.first { $0.name == name }
        let folder = mini?.folder ?? Gallery.folder(install.runs, name)
        let settings = mini?.settings ?? folder.map(MiniSettings.load) ?? MiniSettings()
        var e = Estimator.estimate(JobShape(kind, settings: settings, sizes: sizes), history: history)
        if waiting, kind == .generate, let folder {
            for step in Pipeline.skipped(folder, sides: settings.source == .image ? settings.sides ?? [] : []) { e.steps[step] = nil }
        }
        // One that stops for its picture to be checked (#156) is done once it's made.
        if kind == .generate, let folder, Pipeline.pausesAfterPicture(folder, settings: settings) {
            e.steps[.shape] = nil; e.steps[.print] = nil
        }
        return e
    }

    /// Each waiting job with its estimate and the seconds until it should be ready: the running
    /// job's time left, then each in turn.
    public func queueTimes(_ queue: [QueueEntry], running: JobStatus?, history: [TimingRecord], now: Date = Date(), minis: [Mini] = [])
        -> [(entry: QueueEntry, estimate: Estimate, ready: TimeInterval)] {
        var t = running.map { estimate($0.name, $0.kind, history: history, minis: minis).left($0, now: now) } ?? 0
        return queue.map { e in
            let est = estimate(e.name, e.job, sizes: e.sizes, history: history, minis: minis, waiting: true)
            t += est.total
            return (e, est, t)
        }
    }

    /// The seconds until `name`, waiting in `queue`, should be ready; nil when it isn't waiting.
    public func readyIn(_ name: String, queue: [QueueEntry], running: JobStatus?, history: [TimingRecord], now: Date = Date(),
                        minis: [Mini] = []) -> TimeInterval? {
        queueTimes(queue, running: running, history: history, now: now, minis: minis).first { $0.entry.name == name }?.ready
    }
}
