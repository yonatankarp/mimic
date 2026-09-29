import Foundation
import simd

/// Print prep: turns the 3D engine's model into a printable mini, plus preview renders.
///
///     mimic _prep in.glb out.stl [--height 32] [--base 25] [--base-height 3] [--nozzle 0.4]
///         [--inflate MM] [--voxel MM] [--faces 800000] [--no-base] [--flatten 0.4]
///         [--fit height|longest] [--ground feet|bottom]
///
/// Units are millimetres. Steps: scale to --height, centre on what the figure stands on,
/// inflate the surface by --inflate (thickens blades and staffs by twice that), stand it on a
/// round base, make everything one watertight solid, keep the largest piece, slice the bottom
/// flat, trim the face count, write the STL, render front/side/back PNGs next to it.
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
    /// Base diameter.
    public var base = 25.0
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

    public init(glb: String, stl: String) { self.glb = glb; self.stl = stl }

    public var effectiveInflate: Double { inflate ?? (0.4 * nozzle * 1000).rounded() / 1000 }
    public var effectiveVoxel: Double { voxel ?? (nozzle / 4 * 1000).rounded() / 1000 }

    public static func parse(_ args: [String]) throws -> PrepOptions {
        var rest = args[...], files: [String] = []
        var o = PrepOptions(glb: "", stl: "")
        func number(_ flag: String) throws -> Double {
            guard let v = rest.popFirst(), let n = Double(v), n.isFinite, n >= 0 else { throw PrepError("\(flag) needs a number of 0 or more") }
            return n
        }
        while let a = rest.popFirst() {
            switch a {
            case "--height": o.height = try number(a)
            case "--base": o.base = try number(a)
            case "--base-height": o.baseHeight = try number(a)
            case "--nozzle": o.nozzle = try number(a)
            case "--inflate": o.inflate = try number(a)
            case "--voxel": o.voxel = try number(a)
            case "--flatten": o.flatten = try number(a)
            case "--faces": o.faces = Int(try number(a))
            case "--no-base": o.noBase = true
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
        guard o.height > 0, o.effectiveVoxel > 0 else { throw PrepError("--height and --voxel must be more than 0") }
        o.glb = files[0]; o.stl = files[1]
        return o
    }
}

public enum Prep {
    public struct Result {
        public var mesh: Mesh
        public var dropped: Int
        public var footprint: Double
        public var lines: [String]
    }

    /// Makes the print file and returns what it printed. Renders are separate (`Render`).
    public static func run(_ o: PrepOptions, log: (String) -> Void = { _ in }) throws -> Result {
        var clock = Date()
        func lap(_ what: String) { log(String(format: "prep: %@ %.1f s", what, Date().timeIntervalSince(clock))); clock = Date() }

        var mesh = try GLB.read(URL(fileURLWithPath: o.glb))
        lap("read \(mesh.triangles.count) triangles")
        let height = Float(o.height)

        // Ground is where most of the bottom is, not the lowest vertex: a trailing wisp or
        // hanging tassel is a sliver of the surface below the 0.5th percentile, and ends up
        // sunk into the base instead of holding the figure up on a pin.
        let top = mesh.bounds.hi.z
        var samples = mesh.surfaceSamples()
        let ground0 = Mesh.percentileZ(samples, 0.005)
        // An object's extents skip the same sliver at each end, so a floating speck the
        // generator left (dropped later) can't count as part of its longest side.
        let extent: (lo: SIMD3<Float>, hi: SIMD3<Float>)? = o.fitLongest || o.groundBottom
            ? (SIMD3((0..<3).map { Mesh.percentile(samples, 0.005, axis: $0) }), SIMD3((0..<3).map { Mesh.percentile(samples, 0.995, axis: $0) }))
            : nil
        let span: Float
        if o.fitLongest, let e = extent { span = max(e.hi.x - e.lo.x, e.hi.y - e.lo.y, e.hi.z - ground0) } else { span = top - ground0 }
        let scale = height / span
        for n in mesh.positions.indices { mesh.positions[n] *= scale }
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
            for p in samples where p.z >= ground && p.z <= ground + 0.15 * height {
                reach = max(reach, simd_length(SIMD2(p.x, p.y) - centre))
            }
        }
        let footprint = 2 * Double(reach)

        // Sink the feet 0.6 mm into the base so the two are one solid.
        let feet: Float = o.noBase ? 0 : Float(o.baseHeight) - 0.6
        let shift = SIMD3(centre.x, centre.y, ground - feet)
        for n in mesh.positions.indices { mesh.positions[n] -= shift }
        lap("placed")

        // One watertight solid: the inflated figure fused to a base with a rounded top edge
        // (like a commercial base), cut flat underneath because generated bases carry bumps.
        // z = 0 is the base's underside, or the ground with --no-base; anything below --flatten goes.
        let base = o.noBase ? nil : Solid.Base(radius: Float(o.base) / 2, height: Float(o.baseHeight),
                                               bevel: min(0.6, Float(o.baseHeight) / 3))
        let solid = Solid(mesh: mesh, voxel: Float(o.effectiveVoxel), inflate: Float(o.effectiveInflate),
                          base: base, cut: o.flatten > 0 ? Float(o.flatten) : nil)
        var out = solid.surface(mesh)
        mesh = Mesh()
        lap("solid \(solid.nx)x\(solid.ny)x\(solid.nz) grid, \(out.triangles.count) triangles")

        // Keep only the largest connected piece: drops floating specks the generator left.
        let (piece, dropped) = out.largestPiece()
        out = piece
        let down = SIMD3<Float>(0, 0, Float(o.flatten))
        for n in out.positions.indices { out.positions[n] -= down }
        lap("largest piece")

        // A fine voxel keeps detail but makes millions of faces; collapsing a dense, even mesh
        // back down loses nothing a 0.2 mm nozzle can print and keeps the STL openable.
        if out.triangles.count > o.faces {
            out = Decimate.run(consume out, target: o.faces)
            lap("trimmed to \(out.triangles.count) triangles")
        }

        try STL.write(out, to: URL(fileURLWithPath: o.stl))
        lap("written")

        let (lo, hi) = out.bounds
        var lines = [String(format: "mini_prep: %@  size %.1f x %.1f x %.1f mm  faces %d  loose pieces dropped %d  footprint %.1f mm",
                            o.stl, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, out.triangles.count, dropped, footprint)]
        // An object on a base is a plinth, not a figure that must stand on it: no warning.
        if !o.noBase && !o.groundBottom && footprint > o.base {
            lines.append(String(format: "mini_prep: WARNING footprint %.1f mm is wider than the %.0f mm base; raise the base to at least %d mm",
                                footprint, o.base, Int((footprint + 1).rounded(.up))))
        }
        return Result(mesh: out, dropped: dropped, footprint: footprint, lines: lines)
    }
}

extension Mesh {
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

    /// The coordinate on `axis` (0 x, 1 y, 2 z) below which `fraction` of the surface area lies.
    static func percentile(_ samples: [SIMD4<Float>], _ fraction: Float, axis: Int) -> Float {
        let sorted = samples.sorted { $0[axis] < $1[axis] }
        let goal = sorted.reduce(0) { $0 + $1.w } * fraction
        var below: Float = 0
        for s in sorted {
            below += s.w
            if below >= goal { return s[axis] }
        }
        return sorted.last?[axis] ?? 0
    }

    /// The z below which `fraction` of the surface area lies.
    static func percentileZ(_ samples: [SIMD4<Float>], _ fraction: Float) -> Float { percentile(samples, fraction, axis: 2) }

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

