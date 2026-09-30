import Foundation

/// The print settings of a mini: what print prep is asked for, and what a finished run made.
///
/// Stored in settings.json as strings ("32", nobase "1"), the format the web version wrote, so
/// minis made by either version read the same. Numbers are accepted when reading.
public struct Sizes: Equatable, Sendable {
    public var height: String?
    public var base: String?
    public var nozzle: String?
    public var inflate: String?
    public var noBase = false
    /// Round unless chosen, and always round with no base: so a mini made before shapes, or one
    /// without a base, reads the same as one made now (Resize All leaves minis already its size).
    public var shape = BaseShape.round
    /// Plain unless chosen, and always plain with no base, like the shape.
    public var style = BaseStyle.plain
    /// None unless chosen, and always none with no base, like the shape.
    public var magnet: Magnet?

    public init(height: String? = nil, base: String? = nil, nozzle: String? = nil, inflate: String? = nil, noBase: Bool = false,
                shape: BaseShape = .round, style: BaseStyle = .plain, magnet: Magnet? = nil) {
        self.height = height; self.base = base; self.nozzle = nozzle; self.inflate = inflate; self.noBase = noBase
        self.shape = noBase ? .round : shape
        self.style = noBase ? .plain : style
        self.magnet = noBase ? nil : magnet
    }

    /// Checks every value, then returns print prep's flags. Throws before anything is saved.
    public func flags() throws -> [String] {
        var out: [String] = []
        for (key, value) in [("height", height), ("base", base), ("inflate", inflate)] {
            guard let value else { continue }
            // Double("nan") and Double("inf") parse; neither is a size.
            guard let n = Double(value), n.isFinite, n >= 0 else { throw RequestError.badNumber(key) }
            out += ["--\(key)", String(n)]
        }
        if let nozzle {
            guard Rules.nozzles.contains(nozzle) else { throw RequestError.badNozzle }
            out += ["--nozzle", nozzle]
        }
        if noBase { out.append("--no-base"); return out }
        if shape != .round { out += ["--base-shape", shape.rawValue] }
        if style != .plain { out += ["--base-style", style.rawValue] }
        if let magnet { out += ["--magnet", magnet.rawValue] }
        return out
    }
}

extension Sizes: Codable {
    private enum K: String, CodingKey { case height, base, nozzle, inflate, nobase, shape, style, magnet }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func text(_ k: K) -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Double.self, forKey: k) { return n == n.rounded() ? String(Int(n)) : String(n) }
            return nil
        }
        height = text(.height); base = text(.base); nozzle = text(.nozzle); inflate = text(.inflate)
        noBase = text(.nobase) == "1" || (try? c.decode(Bool.self, forKey: .nobase)) == true
        shape = noBase ? .round : text(.shape).flatMap(BaseShape.init) ?? .round
        style = noBase ? .plain : text(.style).flatMap(BaseStyle.init) ?? .plain
        magnet = noBase ? nil : text(.magnet).flatMap(Magnet.init)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(base, forKey: .base)
        try c.encodeIfPresent(nozzle, forKey: .nozzle)
        try c.encodeIfPresent(inflate, forKey: .inflate)
        if noBase { try c.encode("1", forKey: .nobase) }
        if !noBase && shape != .round { try c.encode(shape.rawValue, forKey: .shape) }
        if !noBase && style != .plain { try c.encode(style.rawValue, forKey: .style) }
        if !noBase, let magnet { try c.encode(magnet.rawValue, forKey: .magnet) }
    }
}

/// The base's outline. Its size is the width across it: a round base's diameter, a square's
/// side, a hex's width across the flats (a hex map's hexes are measured that way). A square or
/// hex faces the figure with a flat side.
public enum BaseShape: String, CaseIterable, Sendable {
    case round, square, hex
}

/// What the top of the base looks like: flat, or a floor pressed into it (Solid.relief).
public enum BaseStyle: String, CaseIterable, Sendable {
    case plain, stone, wood, cobble

    /// "stone floor": how the mini's page and the size card name it.
    public var words: String {
        switch self {
        case .plain: "plain"
        case .stone: "stone floor"
        case .wood: "wooden floor"
        case .cobble: "cobblestones"
        }
    }
}

/// A round magnet the base has a hole for, underneath, to glue it into: tabletop players
/// magnetise bases to hold minis on a steel sheet or in a tin. Named as magnets are sold,
/// diameter by height in millimetres.
public enum Magnet: String, CaseIterable, Sendable {
    case mm5x2 = "5x2", mm6x2 = "6x2", mm8x3 = "8x3"

    public var diameter: Double {
        switch self { case .mm5x2: 5; case .mm6x2: 6; case .mm8x3: 8 }
    }
    public var height: Double { self == .mm8x3 ? 3 : 2 }

    /// "5 × 2 mm": how the size card and the mini's page name it.
    public var words: String { "\(Int(diameter)) × \(Int(height)) mm" }
}

/// What a mini is of. Stored as settings.json's "kind" only for an object: absent means a
/// character, so minis made before objects existed (and by the web version) read unchanged.
public enum MiniKind: String, Codable, Sendable { case character, object }

/// A mini's settings.json: how it was made, the sizes last requested (what Try Again reuses)
/// and the sizes a finished run made (what "Now: …" shows).
public struct MiniSettings: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case image, desc }
    public var source: Source?
    /// The description the picture was drawn from; when the AI helper improved it, the improved
    /// text (Try Again reuses it and never asks the helper again).
    public var desc: String?
    /// What the person typed, kept only when the helper's improved text was used instead.
    public var descOriginal: String?
    public var restyle: Bool?
    public var seed: Int?
    /// The 3D engine's own seed, when New 3D Shape gave it one: the picture keeps `seed`, the
    /// shape starts from this. Absent means `seed` drives both.
    public var shapeSeed: Int?
    /// The 3D model set it's made with (`EngineModel.id`), so Try Again uses the same one.
    /// Absent means the standard set.
    public var model: String?
    /// Made as a cartoon (#3): shown on its page, and kept by Make Another Version. Absent is no.
    public var cartoon: Bool?
    public var requested: Sizes?
    public var made: Sizes?
    /// nil is a character.
    public var kind: MiniKind?
    /// The first of its versions, when Make Another Version made it: every version of a mini
    /// names the same one, which is how they're found together (see `Gallery.versions`).
    public var versionOf: String?
    /// When it was asked for, which the list is sorted by. Older minis have none: their folder's
    /// creation date stands in (see `Gallery.created`).
    public var created: Date?
    /// What the last finished run wants you to know (a part left out, how it stands) and
    /// whether thin parts may be fragile: shown on the mini's page until a run replaces them,
    /// after a relaunch too (#80).
    public var notes: [String]?
    public var fragile: Bool?
    /// Why the last run failed, and at which step, until one finishes: what the page says of a
    /// mini that didn't finish (#78).
    public var failed: String?
    public var failedStep: Int?

    public init() {}

    public var isObject: Bool { kind == .object }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("settings.json") }

    /// Dates as readable text, to the millisecond, so minis asked for together still sort in order.
    private static let dates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Unreadable or missing reads as empty: a mini made before settings existed has none.
    public static func load(_ folder: URL) -> MiniSettings {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { try dates.parse($0.singleValueContainer().decode(String.self)) }
        guard let data = try? Data(contentsOf: file(folder)),
              let s = try? dec.decode(MiniSettings.self, from: data) else { return MiniSettings() }
        return s
    }

    /// Read, change, write back: later writes add to earlier ones, like the web version's.
    public static func update(_ folder: URL, _ change: (inout MiniSettings) -> Void) throws {
        var s = load(folder)
        change(&s)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .custom { date, e in var c = e.singleValueContainer(); try c.encode(date.formatted(dates)) }
        try enc.encode(s).write(to: file(folder), options: .atomic)
    }
}
