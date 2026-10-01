import Foundation
import simd

/// A print file's size in millimetres, base included, and its volume in mm³: what the 3D view's
/// badge and the details panel show, and `mimic info`.
public struct Measured: Equatable, Sendable {
    public let tall: Int, wide: Int, deep: Int
    public var volume = 0.0
    /// Width, height and depth unrounded, and where the print file's origin (under the base's
    /// middle) is in the 3D view's scene: for drawing the size reference.
    public var exact = SIMD3<Float>.zero
    public var origin = SIMD3<Float>.zero

    public init(tall: Int, wide: Int, deep: Int, volume: Double = 0, exact: SIMD3<Float> = .zero, origin: SIMD3<Float> = .zero) {
        self.tall = tall; self.wide = wide; self.deep = deep; self.volume = volume; self.exact = exact; self.origin = origin
    }

    /// From a print file's triangles, three corners each: Z up, the mini facing +Y. Tall is its
    /// Z extent, wide its X and deep its Y, as the 3D view turns it.
    public init(printFile corners: [SIMD3<Float>]) {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for p in corners { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let d = corners.isEmpty ? .zero : hi - lo
        self.init(tall: Int(d.z.rounded()), wide: Int(d.x.rounded()), deep: Int(d.y.rounded()), volume: Filament.volume(corners))
    }

    public init?(stl: URL) {
        guard let corners = try? STL.read(stl) else { return nil }
        self.init(printFile: corners)
    }

    /// "26 × 25 mm"
    public var footprint: String { "\(wide) × \(deep) mm" }
    /// "34 mm tall · 26 × 25 mm", on the 3D view's badge.
    public var caption: String { "\(tall) mm tall · \(footprint)" }
}

/// Where a mini is, as `mimic list` says it.
public enum MiniState: String, Sendable {
    case ready, unfinished, waiting

    public init(_ mini: Mini, waiting: Set<String>) {
        self = waiting.contains(mini.name) ? .waiting : mini.stl == nil ? .unfinished : .ready
    }
}

/// `mimic info <name>`: what a mini's page and details panel say about it, its size, the
/// filament it takes, how it was made (`MadeFrom`) and its versions.
public struct MiniInfo {
    public let mini: Mini
    public let state: MiniState
    /// What its print file measures, when it has one.
    public let measured: Measured?
    public let madeFrom: MadeFrom
    /// Its versions, itself included, by folder name (`Gallery.versions`).
    public let versions: [Mini]

    public init(_ mini: Mini, in minis: [Mini], waiting: Set<String>, now: Date = Date(), timeZone: TimeZone = .current) {
        self.mini = mini
        state = MiniState(mini, waiting: waiting)
        measured = mini.stl.flatMap { Measured(stl: $0) }
        madeFrom = MadeFrom(mini.settings, created: mini.created, now: now, timeZone: timeZone)
        versions = Gallery.versions(of: mini, in: minis)
    }

    public var kind: MiniKind { mini.settings.kind ?? .character }

    /// As `mimic info` prints it: a label and its value a line.
    public var lines: [String] {
        var out = ["\(mini.displayName) (\(mini.name))", "Project: \(mini.project ?? "Unsorted")", "State: \(state.rawValue)"]
        if let made = mini.settings.made { out += PrintTips.made(made, kind: kind).map { "\($0.label): \($0.value)" } }
        if let m = measured {
            out += ["Height with base: \(m.tall) mm", "Footprint: \(m.footprint)", "Filament: \(Filament.words(m.volume))"]
        }
        out += madeFrom.rows.map { "\($0.label): \($0.value)" }
        if let d = madeFrom.description { out.append("Description: \(d)") }
        out += madeFrom.fixes.map { "Changed: \($0)" }
        if versions.count > 1 {
            out.append("Versions: " + versions.map { $0.name == mini.name ? "\($0.name) (this one)" : $0.name }.joined(separator: ", "))
        }
        if let failed = mini.settings.failed, state == .unfinished { out.append("Didn't finish: \(failed)") }
        out.append("Folder: \(mini.folder.path)")
        return out
    }
}
