import Foundation
import simd

/// Print prep: turns the 3D engine's model into a printable mini, plus preview renders.
///
///     mimic _prep in.glb out.stl [--height 32] [--base 25] [--base-height 3] [--nozzle 0.4]
///         [--inflate MM] [--voxel MM] [--faces 800000] [--no-base] [--flatten 0.4]
///         [--fit height|longest] [--ground feet|bottom] [--turn DEG] [--base-shape round|square|hex]
///         [--base-style plain|stone|wood|cobble] [--base-seed N] [--magnet 5x2|6x2|8x3|none]
///
/// Units are millimetres. Steps: scale to --height, centre on what the figure stands on,
/// inflate the surface by --inflate (thickens blades and staffs by twice that), stand it on a
/// base (round, square or hex; --base is its width, across the flats for a hex; its top plain
/// or a floor pressed into it, laid out by --base-seed, and a hole underneath for --magnet), make everything one watertight
/// solid, keep the largest piece, slice the bottom flat, trim the face count, write the STL, render front/left/right/back PNGs next to it,
/// and say in placement.json beside it where the model was put (`Placement`).
///
/// Ported from pipeline/mini_prep.py, which ran inside Blender; every step exists because of a
/// real failure, and the comments keep why. It runs as its own program (a hidden subcommand of
/// the app's binary) so Stop can end it like any other step.
///
/// An object (anything that isn't a character) is `--fit longest --ground bottom`: --height is
/// then its longest side, and it is centred on its whole shadow rather than on its feet.
public struct PrepOptions: Equatable, Sendable {
    public var glb: String
    public var stl: String
    /// Figure height, feet to top; with `fitLongest`, the longest side.
    public var height = 32.0
    /// Size by the longest side (x, y or z) instead of the height.
    public var fitLongest = false
    /// Centre on the whole object's shadow instead of the cross-sections through its feet.
    public var groundBottom = false
    /// Base width: a round base's diameter, a square's side, a hex's width across the flats.
    public var base = 25.0
    public var baseShape = BaseShape.round
    public var baseStyle = BaseStyle.plain
    /// Lays out the stones or planks of a --base-style floor.
    public var baseSeed = 0
    public var baseHeight = 3.0
    /// Printer nozzle; sets the inflate and the voxel.
    public var nozzle = 0.4
    /// Surface offset. A wider nozzle drops thinner walls, so thin parts need more help to
    /// survive the slicer: 0.4 × nozzle was tuned on a 0.2 nozzle (0.08 mm keeps its cloth
    /// whole); 0.15 there already looked melted.
    public var inflate: Double?
    /// Grid spacing. A quarter of the nozzle: finer than any printer line, and never finer than
    /// that line can show. A fixed 0.05 mm, tuned on a 0.2 nozzle, made a 100 mm figure on a
    /// 0.4 nozzle remesh ~10x the faces and sit in Blender for many minutes using 8 GB.
    public var voxel: Double?
    /// Keep the model's own base.
    public var noBase = false
    /// Slice this much off the bottom.
    public var flatten = 0.4
    /// Trim to about this many triangles.
    public var faces = 800_000
    /// Turn the model this many degrees about its vertical axis first, so it faces the front:
    /// Pixal3D writes its figures facing away from where TRELLIS.2's face (EngineModel.turn).
    public var turn = 0.0
    /// A hole under the base for this magnet; none without a base.
    public var magnet: Magnet?

    public init(glb: String, stl: String) { self.glb = glb; self.stl = stl }

    public var effectiveInflate: Double { inflate ?? (0.4 * nozzle * 1000).rounded() / 1000 }
    public var effectiveVoxel: Double { voxel ?? (nozzle / 4 * 1000).rounded() / 1000 }

    /// The magnet hole: its width, with room for the nozzle (a printed hole comes out a little
    /// smaller than drawn, more so on a wide nozzle), and its depth up from the printed bottom,
    /// with a little room for glue.
    public var hole: (width: Double, depth: Double)? {
        guard let magnet, !noBase else { return nil }
        return (magnet.diameter + max(0.2, nozzle / 2), magnet.height + 0.2)
    }
    /// Solid kept over the hole: enough layers to bridge it, clear of the floor's seams.
    static let roof = 0.8
    /// The base's height as made: raised when the magnet's hole wouldn't leave `roof` over it.
    /// The default 3 mm base is 2.6 mm once the bottom is sliced flat, too thin for any of them.
    public var effectiveBaseHeight: Double {
        guard let hole else { return baseHeight }
        let seams = baseStyle == .plain ? 0 : Double(Solid.Floor(baseStyle).depth)
        return max(baseHeight, flatten + hole.depth + Self.roof + seams)
    }

    public static func parse(_ args: [String]) throws -> PrepOptions {
        var rest = args[...], files: [String] = []
        var o = PrepOptions(glb: "", stl: "")
        // Wider than New Mini's ranges, to experiment with, but never a figure or grid the Mac
        // can't hold: a 10²⁰ mm height from a hand edit ran it out of memory (#377).
        func number(_ flag: String, _ range: ClosedRange<Double> = 0...Double.greatestFiniteMagnitude) throws -> Double {
            guard let v = rest.popFirst(), let n = Double(v), range.contains(n) else {
                throw PrepError(range.upperBound == .greatestFiniteMagnitude ? "\(flag) needs a number of 0 or more"
                                : "\(flag) needs a number from \(SizeCard.text(range.lowerBound)) to \(SizeCard.text(range.upperBound))")
            }
            return n
        }
        while let a = rest.popFirst() {
            switch a {
            case "--height": o.height = try number(a, 5...500)
            case "--base": o.base = try number(a, 5...200)
            case "--base-height": o.baseHeight = try number(a, 0...50)
            case "--nozzle": o.nozzle = try number(a, 0.1...1)
            case "--inflate": o.inflate = try number(a, 0...2)
            case "--voxel": o.voxel = try number(a, 0.01...5)
            case "--flatten": o.flatten = try number(a, 0...50)
            case "--faces":
                // Int(1e20) would crash (#378).
                guard let n = rest.popFirst().flatMap(Int.init), (1_000...5_000_000).contains(n) else {
                    throw PrepError("--faces needs a whole number from 1000 to 5000000")
                }
                o.faces = n
            case "--turn": o.turn = try number(a)
            case "--no-base": o.noBase = true
            case "--magnet":
                let v = rest.popFirst()
                guard v == "none" || v.flatMap(Magnet.init) != nil else { throw PrepError("--magnet needs 5x2, 6x2, 8x3 or none") }
                o.magnet = v.flatMap(Magnet.init)
            case "--base-shape":
                guard let s = rest.popFirst().flatMap(BaseShape.init) else { throw PrepError("--base-shape needs round, square or hex") }
                o.baseShape = s
            case "--base-style":
                guard let s = rest.popFirst().flatMap(BaseStyle.init) else { throw PrepError("--base-style needs plain, stone, wood or cobble") }
                o.baseStyle = s
            case "--base-seed":
                guard let n = rest.popFirst().flatMap(Int.init) else { throw PrepError("--base-seed needs a whole number") }
                o.baseSeed = n
            case "--fit":
                switch rest.popFirst() {
                case "height": o.fitLongest = false
                case "longest": o.fitLongest = true
                default: throw PrepError("--fit needs height or longest")
                }
            case "--ground":
                switch rest.popFirst() {
                case "feet": o.groundBottom = false
                case "bottom": o.groundBottom = true
                default: throw PrepError("--ground needs feet or bottom")
                }
            default:
                guard !a.hasPrefix("-") else { throw PrepError("unknown option \(a)") }
                files.append(a)
            }
        }
        guard files.count == 2 else { throw PrepError("usage: mimic _prep in.glb out.stl [options]") }
        o.glb = files[0]; o.stl = files[1]
        return o
    }
}

/// What print prep tells the job that ran it, in prep-result.json beside the print file: its
/// warnings and why it failed. prep.log says the same for people; the job reads only this, so
/// rewording a line there changes nothing it shows.
public struct PrepReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A part left out, and an object that can't stand without a base: said as they are.
        case part, stand
        /// The bottom of a figure wider than its base: `footprintNote`.
        case footprint
    }
    public struct Warning: Codable, Equatable, Sendable {
        public var kind: Kind
        public var text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }
    public var warnings: [Warning] = []
    public var failure: String?

    public init(warnings: [Warning] = [], failure: String? = nil) { self.warnings = warnings; self.failure = failure }

    /// The report for the print file `stl`.
    public static func file(beside stl: URL) -> URL { stl.deletingLastPathComponent().appendingPathComponent("prep-result.json") }

    public func write(beside stl: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.file(beside: stl), options: .atomic)
    }

    /// The report in `folder`, or nil when there's none (prep didn't get as far, or was stopped).
    public static func read(_ folder: URL) -> PrepReport? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("prep-result.json")) else { return nil }
        return try? JSONDecoder().decode(PrepReport.self, from: data)
    }

    /// What the person is told as it is, once each.
    public var notes: [String] {
        warnings.filter { $0.kind != .footprint }.map(\.text).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Whether `footprintNote` is said: any warning that isn't said as it is. (Named when it was
    /// said as "some thin parts may be fragile"; kept, since minis saved it as that.)
    public var fragile: Bool { warnings.contains { $0.kind != .part && $0.kind != .stand } }

    /// What's said for `fragile`, the footprint warning.
    public static let footprintNote = "The bottom of the figure reaches past the edge of its base. Resize This Mini with a bigger base size to fit it on."
}

/// Where print prep put the 3D engine's model (#256), in placement.json beside the print file:
/// where each point of model.glb, read z up as Blender imports it (`GLB.read`), lands on the print
/// file, in millimetres. One matrix for every step that moves it (the turn round, levelling and
/// resting an object, the scale, the shift onto the base and the flattened bottom), so a colour
/// can be found on the engine's model for any point of the print file. Minis prepped before it
/// have none: `EngineColours` places their model again.
public struct Placement: Codable, Equatable, Sendable {
    /// Row by row: the print file's (x, y, z, 1) is this times the model's (x, y, z, 1).
    public var matrix: [[Double]]

    public init(_ m: simd_double4x4) { matrix = (0..<4).map { r in (0..<4).map { m[$0][r] } } }

    /// The matrix, or nil when the file's isn't one that can be undone.
    public var toPrint: simd_double4x4? {
        guard matrix.count == 4, matrix.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let m = simd_double4x4(rows: matrix.map { SIMD4($0[0], $0[1], $0[2], $0[3]) })
        return abs(simd_determinant(m)) > 1e-12 ? m : nil
    }

    public static let file = "placement.json"

    public func write(beside stl: URL) throws {
        try JSONEncoder().encode(self).write(to: stl.deletingLastPathComponent().appendingPathComponent(Self.file), options: .atomic)
    }

    /// The record in `folder`, or nil when there's none that reads.
    public static func read(_ folder: URL) -> simd_double4x4? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        return (try? JSONDecoder().decode(Placement.self, from: data))?.toPrint
    }
}

public enum Prep {
    public struct Result {
        public var mesh: Mesh
        public var dropped: Int
        public var footprint: Double
        public var lines: [String]
        /// The warnings among `lines`, for the job (`PrepReport`).
        public var warnings: [PrepReport.Warning]
        /// Where the 3D engine's model went: `Placement`.
        public var toPrint: simd_double4x4
    }

    /// Makes the print file and returns what it printed. With `views`, the previews beside it
    /// (`Render.views`) are drawn first: a resize stopped or failing while they're drawn keeps
    /// the old print file, which its settings still give the size of (#172).
    public static func run(_ o: PrepOptions, views: Bool = false, log: (String) -> Void = { _ in }) throws -> Result {
        // A record only ever sits beside the print file it was written with: one left by an
        // earlier run goes now, so a run that stops or fails leaves none rather than a stale one.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: o.stl).deletingLastPathComponent().appendingPathComponent(Placement.file))
        var clock = Date()
        func lap(_ what: String) { log(String(format: "prep: %@ %.1f s", what, Date().timeIntervalSince(clock))); clock = Date() }

        var mesh = try GLB.read(URL(fileURLWithPath: o.glb))
        lap("read \(mesh.triangles.count) triangles")
        let placed = try place(&mesh, o, leavingOutItsBase: true, log: log)
        let standsAlone = placed.standsAlone, footprint = placed.footprint
        let height = Float(o.height), baseHeight = o.effectiveBaseHeight
        let thing = o.groundBottom ? "object" : "figure"
        lap("placed")

        // One watertight solid: the inflated figure fused to a base with a rounded top edge
        // (like a commercial base), cut flat underneath because generated bases carry bumps.
        // z = 0 is the base's underside, or the ground with --no-base; anything below --flatten goes.
        let base = o.noBase ? nil : Solid.Base(radius: Float(o.base) / 2, height: Float(baseHeight),
                                               bevel: min(0.6, Float(baseHeight) / 3), shape: o.baseShape,
                                               floor: Solid.Floor(o.baseStyle, nozzle: Float(o.nozzle), seed: o.baseSeed),
                                               hole: o.hole.map { Solid.Hole(radius: Float($0.width) / 2, top: Float(max(0, o.flatten) + $0.depth)) })
        let solid = Solid(mesh: mesh, voxel: Float(o.effectiveVoxel), inflate: Float(o.effectiveInflate),
                          base: base, cut: o.flatten > 0 ? Float(o.flatten) : nil, figureFloor: placed.figureFloor)
        var out = solid.surface(mesh)
        mesh = Mesh()
        lap("solid \(solid.nx)x\(solid.ny)x\(solid.nz) grid, \(out.triangles.count) triangles")

        // Keep only the largest connected piece: drops floating specks the generator left, and
        // the inner walls of hollows (which fills them). A solid piece at least a tenth of the
        // height long is no speck but a held thing the generator didn't join to the hands (a
        // Pixal3D elf's bow): still left out, since it would print floating in mid-air, but said.
        let (piece, kept, loose) = out.largestPiece()
        out = piece
        let dropped = loose.count
        let parts = loose.filter { ($0.volume > 0) == (kept.volume > 0) && Prep.longest($0) >= Prep.partLength * height }
        for n in out.positions.indices { out.positions[n] -= SIMD3(0, 0, Float(o.flatten)) }
        lap("largest piece")

        // A fine voxel keeps detail but makes millions of faces; collapsing a dense, even mesh
        // back down loses nothing a 0.2 mm nozzle can print and keeps the STL openable.
        // A floor on the base keeps its seams, where a plain top collapses to a few faces: it
        // took ~5% of them from the figure (100 mm tiefling, 50 mm base), so it gets that more.
        let faces = o.noBase || o.baseStyle == .plain ? o.faces : o.faces + o.faces / 16
        if out.triangles.count > faces {
            out = Decimate.run(consume out, target: faces)
            lap("trimmed to \(out.triangles.count) triangles")
        }

        if views {
            try Render.views(out, besides: URL(fileURLWithPath: o.stl))
            lap("drew the previews")
        }
        try STL.write(out, to: URL(fileURLWithPath: o.stl))
        try Placement(placed.toPrint).write(beside: URL(fileURLWithPath: o.stl))
        lap("written")

        let (lo, hi) = out.bounds
        var lines = [String(format: "mini_prep: %@  size %.1f x %.1f x %.1f mm  faces %d  loose pieces dropped %d  footprint %.1f mm",
                            o.stl, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, out.triangles.count, dropped, footprint)]
        var warnings: [PrepReport.Warning] = []
        /// A warning: in the log after its marker, and in the report as it is.
        func warn(_ kind: PrepReport.Kind, _ marker: String, _ text: String) {
            lines.append(marker + text); warnings.append(.init(kind, text))
        }
        // An object on a base is a plinth, not a figure that must stand on it: no warning.
        if !o.noBase && !o.groundBottom && footprint > o.base {
            warn(.footprint, "mini_prep: WARNING ", String(format: "footprint %.1f mm is wider than the %.0f mm base; raise the base to at least %d mm",
                                                           footprint, o.base, Int((footprint + 1).rounded(.up))))
        }
        if let magnet = o.magnet {
            lines.append(o.noBase ? "mini_prep: no base, so no magnet hole"
                : String(format: "mini_prep: magnet hole %.1f mm wide, %.1f mm deep, for a ", o.hole!.width, o.hole!.depth)
                    + magnet.words + String(format: " magnet; base %.2f mm tall", baseHeight))
        }
        if o.noBase && !standsAlone {
            warn(.stand, standWarning, "It can't stand on its own, so it was left upright as the 3D engine made it. Turn on \(SizeCard.addBase) to stand it up.")
        }
        if let longest = parts.map(Prep.longest).max() {
            let what = parts.count == 1 ? "A part came out separate from the \(thing) (about \(Int(longest.rounded())) mm long) and was left out."
                : "\(parts.count) parts came out separate from the \(thing) (the largest about \(Int(longest.rounded())) mm long) and were left out."
            warn(.part, partWarning, what + " Try Make Another Version. If you use Pixal3D, TRELLIS.2 (Settings → 3D Model) joins held things more reliably.")
        }
        return Result(mesh: out, dropped: dropped, footprint: footprint, lines: lines, warnings: warnings, toPrint: placed.toPrint)
    }

    /// Where print prep puts the 3D engine's model, in place: turned to face the front, levelled
    /// (an object), sized, and centred on the base with its feet sunk into it. `toPrint` is where
    /// each point of the model as read ends up in the print file: these steps, then the
    /// --flatten that `run` takes off everything once the solid is cut. Kept step by step beside
    /// the positions, which keep their own float arithmetic, so print files come out as before.
    /// Also what Export for Virtual Tabletop places a model by when its mini has no `Placement`.
    /// With `leavingOutItsBase`, a base the engine copied from the picture (`Mesh.baseTop`) is
    /// what the figure stands on: it's measured and set on Mimic's base from that base's top, and
    /// `figureFloor` is where `run` cuts the figure off, so the engine's base isn't printed. Not
    /// when Export for Virtual Tabletop places a model again for a print file made before that.
    static func place(_ mesh: inout Mesh, _ o: PrepOptions, leavingOutItsBase: Bool = false, log: (String) -> Void = { _ in }) throws
        -> (standsAlone: Bool, footprint: Double, toPrint: simd_double4x4, figureFloor: Float?) {
        var toPrint = matrix_identity_double4x4
        if o.turn != 0 {
            // A rotation, not a mirror, so the triangles keep their winding.
            let a = Float(o.turn * .pi / 180), c = cos(a), s = sin(a)
            for n in mesh.positions.indices {
                let p = mesh.positions[n]
                mesh.positions[n] = SIMD3(c * p.x - s * p.y, s * p.x + c * p.y, p.z)
            }
            toPrint = simd_double4x4(simd_quatd(angle: o.turn * .pi / 180, axis: [0, 0, 1]))
        }
        // The 3D engine can leave an object leaning a few degrees (a teapot came out at 5, one
        // drawn from above at 20), and a leaning object prints on the edge of its bottom. A
        // character stands on its feet, which aren't a surface to level, so only objects.
        // After the turn: a turn is about the vertical, so levelling finds the same tilt either
        // way, and the figure's facing is settled before anything is measured.
        var standsAlone = true
        if o.groundBottom {
            let asMade = (mesh.positions, toPrint)
            func moved(_ q: simd_quatf, _ centre: SIMD3<Float>) { toPrint = Prep.rotation(q, about: centre) * toPrint }
            let degrees = mesh.level(moved: moved)
            // Levelling squares up a lean; one levelled onto the edge of its foot instead of the
            // foot is then set on a side near it that it can stand on (Mesh.rest).
            if let turned = mesh.rest(moved: moved) {
                if degrees > 0 { log(String(format: "prep: levelled by %.1f°", degrees)) }
                if turned > 0 { log(String(format: "prep: set on its most stable side (turned %.0f°)", turned)) }
            } else {
                // Nothing near its bottom holds it up (a figure on small feet, a bird on a perch):
                // it stays as the engine made it, since levelling read a raven's tail and perch
                // as a lean and tipped it 27° onto nothing it could stand on either.
                (mesh.positions, toPrint) = asMade
                standsAlone = false
            }
        }
        let height = Float(o.height)

        // Ground is where most of the bottom is, not the lowest vertex: a trailing wisp or
        // hanging tassel is a sliver of the surface below the 0.5th percentile, and ends up
        // sunk into the base instead of holding the figure up on a pin.
        let top = mesh.bounds.hi.z
        var samples = mesh.surfaceSamples()
        var ground0 = Mesh.percentileZ(samples, 0.005)
        // A base in the picture comes back as a base of the engine's own: a hollow drum, often
        // wider than Mimic's, which printed hanging over it on supports, its rim ragged where it
        // was cut flat. The figure stands on its top instead, and the drum is left out.
        var ownBase = false
        if leavingOutItsBase, !o.noBase, !o.groundBottom, let t = mesh.baseTop(ground: ground0, top: top) {
            log(String(format: "prep: left out the 3D model's own base (%.0f%% of its height)", 100 * (t - ground0) / (top - ground0)))
            ground0 = t; ownBase = true
        }
        // An object's extents leave out the floating specks the generator left (dropped later),
        // so one can't count as part of its longest side. Not a percentile of the surface, like
        // the ground: that trims thin tips, and a teapot's spouts came out 90 mm long, not 80.
        let extent = o.fitLongest || o.groundBottom ? mesh.mainBounds() : nil
        // A flat drawing can come back from the engine as a flat sheet (a cartoon gave TRELLIS.2 a
        // square 80 x 80 x 0.1 mm), which prep would otherwise size and write like any mini.
        let e = extent ?? mesh.mainBounds(), size = e.hi - e.lo
        if size.min() < Prep.flat * size.max() { throw PrepError(Prep.flatProblem) }
        let span: Float
        if o.fitLongest, let e = extent { span = max(e.hi.x - e.lo.x, e.hi.y - e.lo.y, e.hi.z - ground0) } else { span = top - ground0 }
        let scale = height / span
        for n in mesh.positions.indices { mesh.positions[n] *= scale }
        toPrint = simd_double4x4(diagonal: SIMD4(Double(scale), Double(scale), Double(scale), 1)) * toPrint
        for n in samples.indices { samples[n] *= SIMD4(scale, scale, scale, scale * scale) }
        let ground = ground0 * scale

        let centre: SIMD2<Float>
        var reach: Float = 0
        if o.groundBottom, let e = extent {
            // An object lies on its whole bottom, so it's centred on its shadow on the bed: a
            // teapot's spout counts, where a character's raised weapon mustn't.
            centre = scale * (SIMD2(e.lo.x, e.lo.y) + SIMD2(e.hi.x, e.hi.y)) / 2
            for p in samples { reach = max(reach, simd_length(SIMD2(p.x, p.y) - centre)) }
        } else {
            // Centre on what the figure stands on: the solid cross-sections through its lower body.
            // Not a box, which a raised weapon or a trailing wisp stretches by its whole length, and
            // not the surface vertices, which count a thin wisp's skin as heavily as a leg's: on the
            // test fixture those were off by 2.0 mm (box) and 0.65 mm (vertex mean).
            var total: Float = 0, sum = SIMD2<Float>()
            for f: Float in [0.03, 0.06, 0.09, 0.12] {
                let s = mesh.section(ground + f * height)
                total += s.area; sum += s.area * s.centroid
            }
            centre = total > 0 ? sum / total : .zero
            // Standing on the engine's base, not its top: that's left out.
            let above = ownBase ? ground + 0.01 * height : ground
            for p in samples where p.z >= above && p.z <= ground + 0.15 * height {
                reach = max(reach, simd_length(SIMD2(p.x, p.y) - centre))
            }
        }
        let footprint = 2 * Double(reach)

        // Sink the feet 0.6 mm into the base so the two are one solid. Standing on the engine's
        // base, the figure is cut off 0.6 mm into Mimic's, and the engine's base top sits further
        // down, so its skin, grown by the inflate, is cut off with it.
        let baseHeight = o.effectiveBaseHeight
        let floor: Float? = ownBase ? Float(baseHeight) - 0.6 : nil
        let feet: Float = o.noBase ? 0 : Float(baseHeight) - 0.6 - (ownBase ? Float(o.effectiveInflate + 2 * o.effectiveVoxel) : 0)
        let shift = SIMD3(centre.x, centre.y, ground - feet)
        for n in mesh.positions.indices { mesh.positions[n] -= shift }
        // `run` takes --flatten off the print file afterwards, whether or not it cut anything.
        var move = matrix_identity_double4x4
        move.columns.3 = SIMD4(-SIMD3<Double>(shift) - SIMD3(0, 0, o.flatten), 1)
        return (standsAlone, footprint, move * toPrint, floor)
    }

    /// Turning by `q` about `centre`, as `level` and `rest` turn a mesh.
    static func rotation(_ q: simd_quatf, about centre: SIMD3<Float>) -> simd_double4x4 {
        var m = simd_double4x4(simd_quatd(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real)))
        let c = SIMD3<Double>(centre), turned = m * SIMD4(c, 1)
        m.columns.3 = SIMD4(c - SIMD3(turned.x, turned.y, turned.z), 1)
        return m
    }

    /// A dropped piece whose longest side is at least this share of the height is a part, not a
    /// speck. Measured (NOTES.md): a lost bow was 93% of the height, the largest solid speck on
    /// seven real minis under 1%.
    static let partLength: Float = 0.1
    /// Marks the warning for a part left out in prep.log; the job reads it from `PrepReport`.
    public static let partWarning = "mini_prep: WARNING part: "
    /// Marks the warning for an object that can't stand without a base, the same way.
    public static let standWarning = "mini_prep: WARNING stand: "
    /// Marks why prep failed in prep.log; the job reads it from `PrepReport` too.
    public static let failure = "mini_prep: FAILED: "
    /// The flat area, in hundredths of the height squared, within 0.5% of the height, that makes
    /// the top of a base the engine made (`Mesh.baseTop`). Measured on 13 real models: three
    /// bases' tops had 1,899 (a fairy's, mostly under her robe) to 5,317; the most of the ten
    /// minis without one was 751, a Pixal3D Lorelei's robe. About 1.6 times from each.
    static let baseFlat: Float = 1200
    /// A model whose thinnest side is under this share of its longest is a flat sheet, not a mini.
    static let flat: Float = 0.02
    static let flatProblem = "The 3D model came out flat, like a sheet of paper. For a flat drawing, turn on \"Turn it into a grey sculpt first\" (--restyle) and make it again."

    static func longest(_ p: Mesh.Piece) -> Float {
        let e = p.hi - p.lo
        return max(e.x, e.y, e.z)
    }
}

extension Mesh {
    /// Turns the mesh so what it stands on faces straight down, and returns by how many degrees.
    /// What it stands on is the downward-facing surface in its lowest tenth: the area-weighted
    /// average of those triangles' facing, which is exact for a flat bottom and the axis for a
    /// round one. Facing is taken as pointing down whichever way a triangle is wound, since the
    /// generator's winding isn't reliable. Past 30° it's more likely a misreading (an object
    /// lying on its side on purpose) than a lean, so it's left alone.
    /// `moved` hears each turn it makes, and about where.
    mutating func level(limit: Float = 30, moved: (simd_quatf, SIMD3<Float>) -> Void = { _, _ in }) -> Float {
        var total: Float = 0
        for _ in 0..<3 {  // the lowest tenth moves as it turns; three passes settle it
            let (lo, hi) = bounds
            let band = lo.z + 0.1 * (hi.z - lo.z)
            var down = SIMD3<Float>.zero
            for t in triangles {
                let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
                guard min(a.z, b.z, c.z) <= band else { continue }
                var n = simd_cross(b - a, c - a)  // its length is twice the area: the weight
                if n.z > 0 { n = -n }
                let length = simd_length(n)
                guard length > 0, n.z / length < -0.7 else { continue }
                down += n
            }
            guard simd_length(down) > 0 else { break }
            down = simd_normalize(down)
            let angle = acos(min(1, -down.z)) * 180 / .pi
            guard angle > 0.2, total + angle <= limit else { break }
            let turn = simd_quatf(from: down, to: [0, 0, -1])
            let centre = (lo + hi) / 2
            for n in positions.indices { positions[n] = turn.act(positions[n] - centre) + centre }
            moved(turn, centre)
            total += angle
        }
        return total
    }

    /// Points spread evenly over the surface, with the area each stands for (x, y, z, area):
    /// the centres of the triangles, long ones split until small. Blender measured the ground
    /// and the footprint on its remeshed vertices, which are even; the generator's are too, but
    /// a mesh of a few long triangles (the test fixture's wisp) isn't.
    func surfaceSamples() -> [SIMD4<Float>] {
        let (lo, hi) = bounds
        let limit = 0.005 * simd_length(hi - lo)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(triangles.count)
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ depth: Int) {
            if max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a)) > limit && depth < 12 {
                let ab = (a + b) / 2, bc = (b + c) / 2, ca = (c + a) / 2
                add(a, ab, ca, depth + 1); add(ab, b, bc, depth + 1); add(ca, bc, c, depth + 1); add(ab, bc, ca, depth + 1)
            } else {
                let centre = (a + b + c) / 3
                out.append(SIMD4(centre, simd_length(simd_cross(b - a, c - a)) / 2))
            }
        }
        for t in triangles { add(positions[Int(t.x)], positions[Int(t.y)], positions[Int(t.z)], 0) }
        return out
    }

    /// The bounds of every connected piece holding at least `share` of the surface area: the
    /// object with its overlapping parts (a separate spout or blade), without the specks. A
    /// mesh with no such piece (not welded, say) gives its whole bounds.
    func mainBounds(share: Float = 0.002) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for (t, keep) in zip(triangles, mainTriangles(share: share)) where keep {
            for v in [t.x, t.y, t.z] { lo = simd_min(lo, positions[Int(v)]); hi = simd_max(hi, positions[Int(v)]) }
        }
        return lo.x <= hi.x ? (lo, hi) : bounds
    }

    /// Per triangle, whether its connected piece holds at least `share` of the surface area.
    func mainTriangles(share: Float = 0.002) -> [Bool] {
        var parent = Array(0..<Int32(positions.count))
        func find(_ x: Int32) -> Int32 {
            var x = x
            while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
            return x
        }
        for t in triangles {
            let a = find(Int32(t.x)), b = find(Int32(t.y)), c = find(Int32(t.z))
            parent[Int(b)] = a; parent[Int(c)] = a
        }
        var area: [Int32: Float] = [:], total: Float = 0
        for t in triangles {
            let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
            let da = simd_length(simd_cross(b - a, c - a)) / 2
            area[find(Int32(t.x)), default: 0] += da; total += da
        }
        return triangles.map { area[find(Int32($0.x)), default: 0] >= share * total }
    }

    /// The top of a base the 3D engine made under a figure, copying one in its picture, from
    /// `ground` (the figure's bottom) and `top`; nil when the figure stands on its own feet. Its
    /// top is a wide flat face, low down, with hardly any flat above it. Flat either way up: the
    /// engine's surfaces are two-sided, and its winding isn't reliable.
    func baseTop(ground: Float, top: Float) -> Float? {
        let height = top - ground
        guard height > 0 else { return nil }
        // Quarter-hundredth bins up to 13%, so a top on a bin's edge is still counted together.
        let bin = height / 400, bins = 52
        var flat = [Float](repeating: 0, count: bins), at = flat
        for t in triangles {
            let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
            let cross = simd_cross(b - a, c - a), twice = simd_length(cross)
            guard twice > 0, abs(cross.z) / twice > 0.95 else { continue }
            let z = (a.z + b.z + c.z) / 3, k = Int(((z - ground) / bin).rounded(.down))
            guard k >= 0, k < bins else { continue }
            flat[k] += twice / 2; at[k] += twice / 2 * z
        }
        // The flat within half a hundredth either side of a bin, and in the hundredth above that.
        func sum(_ r: Range<Int>) -> (area: Float, z: Float) {
            let r = max(0, r.lowerBound)..<min(bins, r.upperBound)
            return (r.reduce(0) { $0 + flat[$1] }, r.reduce(0) { $0 + at[$1] })
        }
        let least = Prep.baseFlat * bin * bin * 16
        // From the highest, so a base in steps gives its top; above the bottom hundredth, which
        // is the soles and the base's underside.
        for k in stride(from: 47, through: 4, by: -1) {
            let here = sum(k - 2..<k + 3)
            guard here.area >= least, sum(k + 3..<k + 7).area < here.area / 5,
                  flat[k] >= flat[max(0, k - 1)], flat[k] >= flat[k + 1] else { continue }
            return here.z / here.area
        }
        return nil
    }

    /// The z below which `fraction` of the surface area lies.
    static func percentileZ(_ samples: [SIMD4<Float>], _ fraction: Float) -> Float {
        let sorted = samples.sorted { $0.z < $1.z }
        let goal = sorted.reduce(0) { $0 + $1.w } * fraction
        var below: Float = 0
        for s in sorted {
            below += s.w
            if below >= goal { return s.z }
        }
        return sorted.last?.z ?? 0
    }

    /// Area and area centroid (x, y) of the solid's horizontal cross-section at height z, from
    /// the loops where the plane cuts the surface (Green's theorem). Sign-agnostic: a mesh wound
    /// inside out gives a negative area and the same centroid, and only the size is used.
    func section(_ z: Float) -> (area: Float, centroid: SIMD2<Float>) {
        var area2: Double = 0, cx: Double = 0, cy: Double = 0
        for t in triangles {
            let v = [positions[Int(t.x)], positions[Int(t.y)], positions[Int(t.z)]]
            var up: SIMD2<Double>?, down: SIMD2<Double>?
            for n in 0..<3 {
                let a = v[n], b = v[(n + 1) % 3]
                guard (a.z < z) != (b.z < z) else { continue }
                let s = Double((z - a.z) / (b.z - a.z))
                let p = SIMD2(Double(a.x) + s * Double(b.x - a.x), Double(a.y) + s * Double(b.y - a.y))
                if a.z < z { up = p } else { down = p }
            }
            guard let p = up, let q = down else { continue }
            let cross = p.x * q.y - q.x * p.y
            area2 += cross; cx += (p.x + q.x) * cross; cy += (p.y + q.y) * cross
        }
        guard area2 != 0 else { return (0, .zero) }
        return (Float(abs(area2) / 2), SIMD2(Float(cx / (3 * area2)), Float(cy / (3 * area2))))
    }
}

