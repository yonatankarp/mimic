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

    public init(height: String? = nil, base: String? = nil, nozzle: String? = nil, inflate: String? = nil, noBase: Bool = false) {
        self.height = height; self.base = base; self.nozzle = nozzle; self.inflate = inflate; self.noBase = noBase
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
        if noBase { out.append("--no-base") }
        return out
    }
}

extension Sizes: Codable {
    private enum K: String, CodingKey { case height, base, nozzle, inflate, nobase }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func text(_ k: K) -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Double.self, forKey: k) { return n == n.rounded() ? String(Int(n)) : String(n) }
            return nil
        }
        height = text(.height); base = text(.base); nozzle = text(.nozzle); inflate = text(.inflate)
        noBase = text(.nobase) == "1" || (try? c.decode(Bool.self, forKey: .nobase)) == true
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(base, forKey: .base)
        try c.encodeIfPresent(nozzle, forKey: .nozzle)
        try c.encodeIfPresent(inflate, forKey: .inflate)
        if noBase { try c.encode("1", forKey: .nobase) }
    }
}

/// A mini's settings.json: how it was made, the sizes last requested (what Try Again reuses)
/// and the sizes a finished run made (what "Now: …" shows).
public struct MiniSettings: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case image, desc }
    public var source: Source?
    public var desc: String?
    public var restyle: Bool?
    public var seed: Int?
    /// The 3D model set it's made with (`EngineModel.id`), so Try Again uses the same one.
    /// Absent (every mini before 0.4.0) means the standard set.
    public var model: String?
    public var requested: Sizes?
    public var made: Sizes?

    public init() {}

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent("settings.json") }

    /// Unreadable or missing reads as empty: a mini made before settings existed has none.
    public static func load(_ folder: URL) -> MiniSettings {
        guard let data = try? Data(contentsOf: file(folder)),
              let s = try? JSONDecoder().decode(MiniSettings.self, from: data) else { return MiniSettings() }
        return s
    }

    /// Read, change, write back: later writes add to earlier ones, like the web version's.
    public static func update(_ folder: URL, _ change: (inout MiniSettings) -> Void) throws {
        var s = load(folder)
        change(&s)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: file(folder), options: .atomic)
    }
}
