import Darwin
import Foundation
import Metal

/// How this Mac's Mimic is set up, for Report a Problem… (#283): what someone fixing it asks
/// first. All of it in the zip (`text`), the part that says most in the issue (`summary`), since
/// a link only takes a few KB. Never a mini's name, a prompt, a key, an address or an account:
/// jobs are counted by kind and step, the AI helper is its provider. Every value is scrubbed.
public struct ReportSetup: Equatable, Sendable {
    /// A job without its mini: what it does, where it got to and how it ended.
    public struct Job: Equatable, Sendable {
        public var kind: JobKind
        public var step: JobStep
        public var outcome: JobOutcome
        /// A print prep that was an import's first, not a resize.
        public var importing: Bool

        public init(kind: JobKind, step: JobStep, outcome: JobOutcome, importing: Bool = false) {
            self.kind = kind; self.step = step; self.outcome = outcome; self.importing = importing
        }

        public init(_ s: JobStatus) { self.init(kind: s.kind, step: s.step, outcome: s.outcome, importing: s.importing) }

        var words: String { kind == .generate ? "make" : importing ? "import" : "resize" }
    }

    public enum PowerSource: String, Equatable, Sendable { case battery, charger, mains }
    public enum MemoryPressure: String, Equatable, Sendable { case normal, warning, critical }
    /// Where the nozzle, base and grey sculpt are from: the mini reported, the last job's mini, or
    /// what New Mini last had chosen.
    public enum SettingsFrom: String, Equatable, Sendable {
        case mini = "this mini", lastJob = "the last job's mini", newMini = "New Mini's last choice"
    }

    /// The 3D model set ("TRELLIS.2") and the engine's VERSION line, nil when it isn't installed.
    public var model: String
    public var engineVersion: String?
    /// The model Draw Things has selected, nil when it isn't answering.
    public var drawThingsModel: String?
    /// Pictures are made with Mimic's draw-things-cli, not the app's API.
    public var drawThingsCLI: Bool
    /// Settings → Open Draw Things when needed.
    public var openDrawThings: Bool
    public var helper: HelperProvider
    /// Free space on the minis folder's disk.
    public var freeBytes: Int64?
    public var memoryPressure: MemoryPressure?
    public var power: PowerSource
    /// Settings → Start minis only when plugged in.
    public var holdOnBattery: Bool
    public var gpu: String?
    /// The job running, here or in another Mimic, and the kinds of those waiting, in order.
    public var running: Job?
    public var waiting: [JobKind]
    public var hold: QueueHold?
    public var lastJob: Job?
    public var sizes: Sizes?
    public var greySculpt: Bool?
    public var settingsFrom: SettingsFrom

    public init(model: String, engineVersion: String? = nil, drawThingsModel: String? = nil, drawThingsCLI: Bool = false,
                openDrawThings: Bool = true, helper: HelperProvider = .off, freeBytes: Int64? = nil,
                memoryPressure: MemoryPressure? = nil, power: PowerSource = .mains, holdOnBattery: Bool = false,
                gpu: String? = nil, running: Job? = nil, waiting: [JobKind] = [], hold: QueueHold? = nil, lastJob: Job? = nil,
                sizes: Sizes? = nil, greySculpt: Bool? = nil, settingsFrom: SettingsFrom = .newMini) {
        self.model = model; self.engineVersion = engineVersion; self.drawThingsModel = drawThingsModel
        self.drawThingsCLI = drawThingsCLI; self.openDrawThings = openDrawThings; self.helper = helper
        self.freeBytes = freeBytes; self.memoryPressure = memoryPressure; self.power = power
        self.holdOnBattery = holdOnBattery; self.gpu = gpu; self.running = running; self.waiting = waiting
        self.hold = hold; self.lastJob = lastJob; self.sizes = sizes; self.greySculpt = greySculpt
        self.settingsFrom = settingsFrom
    }

    // MARK: Reading it

    /// The setup as this Mac has it: the engine, Draw Things, the helper, the disk, memory, power
    /// and GPU. What the app knows (the queue, the last job, the settings) the caller adds. Asks
    /// Draw Things over its API (a second at most when it's closed), so not on the main thread;
    /// never reads its models folder, which would ask the person for access.
    public static func current(install: Install, defaults: UserDefaults = .standard,
                               drawThings: DrawThings? = nil) -> ReportSetup {
        let cli = DrawThings.findCLI(install)
        let version = (try? String(contentsOf: install.engine.appendingPathComponent("VERSION"), encoding: .utf8))?
            .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let power: PowerSource = Power.onBattery() ? .battery : Power.hasBattery() ? .charger : .mains
        return ReportSetup(model: EngineDownload.selected(defaults: defaults).name, engineVersion: version,
                           drawThingsModel: (drawThings ?? DrawThings(cli: cli)).shownModel(), drawThingsCLI: cli != nil,
                           openDrawThings: DrawThingsApp.enabled(defaults), helper: HelperConfig.load(defaults).provider,
                           freeBytes: Checks.freeBytes(install.runs), memoryPressure: memoryPressureNow(), power: power,
                           holdOnBattery: defaults.bool(forKey: Power.key), gpu: MTLCreateSystemDefaultDevice()?.name)
    }

    /// The kernel's memory pressure level: 1 normal, 2 warning, 4 critical.
    static func memoryPressureNow() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return switch level { case 1: .normal; case 2: .warning; case 4: .critical; default: nil }
    }

    // MARK: Writing it

    /// Every line, as label and value, scrubbed.
    public func rows(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [(String, String)] {
        rows(short: false).map { ($0, Report.scrub($1, home: home)) }
    }

    /// All of it, one "Label: value" a line: setup.txt in the zip.
    public func text(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        rows(home: home).map { "\($0): \($1)" }.joined(separator: "\n") + "\n"
    }

    /// The lines that say most, as a Markdown list for the issue, each kept short.
    public func summary(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        rows(short: true).map { "- \($0): \(Report.scrub($1, home: home).prefix(Self.longest))" }.joined(separator: "\n")
    }

    /// The most of one value the issue gets: a long VERSION line or model name stays in the zip.
    static let longest = 100

    private func rows(short: Bool) -> [(String, String)] {
        func step(_ j: Job) -> String { "step \(j.step.rawValue) of \(JobStep.allCases.count) (\(j.step.label))" }
        let engine = model + ", " + (engineVersion ?? "not installed")
        let drawThings = (drawThingsModel ?? "model unknown, Draw Things isn't answering") + ", with "
            + (drawThingsCLI ? "draw-things-cli" : "the Draw Things app")
        let gb = freeBytes.map { Checks.gigabytes($0) + " GB free" } ?? "unknown"
        let last = lastJob.map { j -> String in
            let ended = switch j.outcome {
            case .running: "running"
            case .finished: "finished"
            case .stopped: "stopped"
            case .failed: "failed"
            case .pictureReady: "stopped for its picture to be checked"
            }
            return "\(j.words), \(ended) at \(step(j))"
        } ?? "none since Mimic opened"
        var queue = running.map { "\($0.words) running at \(step($0))" } ?? "nothing running"
        if !waiting.isEmpty {
            let makes = waiting.filter { $0 == .generate }.count
            queue += ", \(waiting.count) waiting (\(makes) make, \(waiting.count - makes) resize)"
        }
        if let hold { queue += hold == .paused ? ", paused" : ", held on battery" }
        var out = [("Engine", engine), ("Draw Things", drawThings), ("AI helper", helper == .off ? "off" : "on, \(helper.rawValue)"),
                   ("Minis folder disk", gb), ("Memory pressure", memoryPressure?.rawValue ?? "unknown"),
                   ("Power", power == .mains ? "mains (no battery)" : power.rawValue), ("GPU", gpu ?? "unknown"),
                   ("Queue", queue), ("Last job", last)]
        guard !short else { return out }
        let s = sizes ?? Sizes()
        let base = s.noBase ? "none"
            : [s.base.map { "\($0) mm" } ?? "standard", s.shape.rawValue, s.style.words, s.magnet.map { "magnet \($0.words)" }]
                .compactMap { $0 }.joined(separator: ", ")
        out += [("Settings from", settingsFrom.rawValue), ("Nozzle", "\(s.nozzle ?? "0.4") mm"), ("Base", base),
                ("Grey sculpt", greySculpt.map { $0 ? "on" : "off" } ?? "asked each time, on to start"),
                ("Priority", "lower (nice \(JobRunner.nice))"), ("Start only when plugged in", holdOnBattery ? "on" : "off"),
                ("Open Draw Things when needed", openDrawThings ? "on" : "off")]
        return out
    }
}
