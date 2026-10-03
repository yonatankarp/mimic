import Foundation

/// `--json` on `mimic list`, `projects`, `queue`, `models` and `info` (#130): what each prints, for scripts.
/// The field names are a promise (docs/cli.md, Terminal): fields may be added, never renamed or
/// removed. Dates are ISO 8601, sizes millimetres, times seconds. A field with no value is left out.
public enum ListingJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func text<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// One mini, as `mimic list --json` lists them (every project's, newest first).
    public struct MiniRow: Codable, Equatable, Sendable {
        /// Its folder's name: what every `mimic` command takes.
        public var name: String
        /// The name it's shown as.
        public var shown: String
        /// Nil when it's unsorted.
        public var project: String?
        /// "ready", "unfinished" or "waiting".
        public var state: String
        /// "character" or "object".
        public var kind: String
        /// When it was asked for.
        public var created: Date
        /// Its print file, once it has one.
        public var file: String?
        public var folder: String

        public init(_ mini: Mini, waiting: Set<String>) {
            name = mini.name; shown = mini.displayName; project = mini.project
            state = MiniState(mini, waiting: waiting).rawValue
            kind = (mini.settings.kind ?? .character).rawValue
            created = mini.created
            file = mini.stl?.path
            folder = mini.folder.path
        }
    }

    /// One project, as `mimic projects --json` lists them (by name).
    public struct Project: Codable, Equatable, Sendable {
        public var name: String
        /// How many minis are in it.
        public var minis: Int

        public init(_ name: String, minis: [Mini]) {
            self.name = name; self.minis = minis.filter { $0.project == name }.count
        }
    }

    /// `mimic queue --json`: the job being made, why the queue waits, and what's waiting.
    public struct Queue: Codable, Equatable, Sendable {
        public struct Running: Codable, Equatable, Sendable {
            public var name: String
            /// "make" or "resize".
            public var job: String
            /// 1 to 3.
            public var step: Int
            public var started: Date
            public var secondsLeft: Int
        }
        public struct Waiting: Codable, Equatable, Sendable {
            /// From 1, the next to start.
            public var place: Int
            public var name: String
            public var job: String
            public var added: Date
            /// How long it takes, and how long until it's ready, from now.
            public var seconds: Int
            public var readyIn: Int
        }
        public var running: Running?
        /// "paused" or "battery", when the next job waits for that.
        public var held: String?
        public var waiting: [Waiting]

        public init(running: JobStatus?, left: TimeInterval, held: QueueHold?,
                    waiting: [(entry: QueueEntry, estimate: Estimate, ready: TimeInterval)]) {
            self.running = running.map { Running(name: $0.name, job: ListingJSON.job($0.kind), step: $0.step.rawValue, started: $0.started, secondsLeft: Int(left.rounded())) }
            self.held = held.map { $0 == .paused ? "paused" : "battery" }
            self.waiting = waiting.enumerated().map { i, row in
                Waiting(place: i + 1, name: row.entry.name, job: ListingJSON.job(row.entry.job), added: row.entry.added,
                        seconds: Int(row.estimate.total.rounded()), readyIn: Int(row.ready.rounded()))
            }
        }
    }

    /// One 3D model set, as `mimic models --json` lists them.
    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var bytes: Int64
        public var downloaded: Bool
        /// The one Mimic makes minis with.
        public var selected: Bool
        public var about: String

        public init(_ m: EngineModel, downloaded: Bool, selected: Bool) {
            id = m.id; name = m.name; bytes = m.bytes; self.downloaded = downloaded; self.selected = selected; about = m.described()
        }
    }

    /// Sizes as a mini was made at them, in millimetres.
    public struct SizesRow: Codable, Equatable, Sendable {
        public var height: Double?
        public var base: Double?
        public var nozzle: Double?
        public var inflate: Double?
        public var noBase: Bool
        /// "round", "square" or "hex".
        public var shape: String
        /// "plain", "stone", "wood" or "cobble".
        public var style: String
        /// "5x2", "6x2" or "8x3".
        public var magnet: String?

        public init(_ s: Sizes) {
            // JSON has no inf or nan, and JSONEncoder throws on them (#379): such a size is left out.
            func mm(_ text: String?) -> Double? { text.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
            height = mm(s.height); base = mm(s.base); nozzle = mm(s.nozzle); inflate = mm(s.inflate)
            noBase = s.noBase; shape = s.shape.rawValue; style = s.style.rawValue; magnet = s.magnet?.rawValue
        }
    }

    /// `mimic info <name> --json`.
    public struct Info: Codable, Equatable, Sendable {
        public struct Measured: Codable, Equatable, Sendable {
            /// With its base.
            public var height: Int
            public var width: Int
            public var depth: Int
            public var filamentGrams: Double
            public var filamentMetres: Double
        }
        public struct MadeFrom: Codable, Equatable, Sendable {
            /// "picture" or "description".
            public var source: String?
            public var description: String?
            /// What was typed, when the AI helper improved it.
            public var typed: String?
            public var seed: Int?
            public var shapeSeed: Int?
            public var model: String?
            public var greySculpt: Bool?
            public var cartoon: Bool?
            /// What was changed in its picture, as typed, oldest first.
            public var fixes: [String]?
        }
        public var mini: MiniRow
        public var made: SizesRow?
        public var measured: Measured?
        public var madeFrom: MadeFrom
        /// Its versions by name, itself included.
        public var versions: [String]
        /// Why its last run didn't finish.
        public var failed: String?

        public init(_ info: MiniInfo, waiting: Set<String>) {
            let s = info.mini.settings
            mini = MiniRow(info.mini, waiting: waiting)
            made = s.made.map(SizesRow.init)
            measured = info.measured.map {
                Measured(height: $0.tall, width: $0.wide, depth: $0.deep, filamentGrams: Filament.grams($0.volume).rounded(toPlaces: 1),
                         filamentMetres: Filament.metres($0.volume).rounded(toPlaces: 2))
            }
            madeFrom = MadeFrom(source: s.source.map { $0 == .image ? "picture" : "description" }, description: s.desc, typed: s.descOriginal,
                                seed: s.seed, shapeSeed: s.shapeSeed,
                                model: s.madeWith?.id, greySculpt: s.source == .image ? s.restyle : nil,
                                cartoon: s.cartoon, fixes: s.fixes)
            versions = info.versions.map(\.name)
            failed = info.state == .unfinished ? s.failed : nil
        }
    }

    static func job(_ kind: JobKind) -> String { kind == .prep ? "resize" : "make" }
}

extension Double {
    func rounded(toPlaces n: Int) -> Double {
        let f = pow(10, Double(n))
        return (self * f).rounded() / f
    }
}
