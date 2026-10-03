import CoreGraphics
import Foundation
import ImageIO
import simd

/// The 3D engine's colours on a mini (#256): for a point on its print file, the base colour of the
/// nearest point on the engine's textured model.glb, found by undoing `Placement`. What Export for
/// Virtual Tabletop paints with, and what a colour print file (#41) can paint with.
public struct EngineColours: Sendable {
    let model: Mesh
    let uv: [SIMD2<Float>]
    let picture: [UInt8], width: Int, height: Int
    let grid: Nearest
    /// The print file back to the model.
    let toModel: simd_double4x4
    /// In the model's own units: past this, it isn't what's there (Mimic's base).
    let far: Float

    /// `toPrint` takes the model to the print file (`Placement`). Nothing of the model further
    /// than `far` of its height as placed is what's at a point.
    public init(model: Mesh, paint: GLB.Paint, toPrint: simd_double4x4, far: Float = 0.03) throws {
        guard let source = CGImageSourceCreateWithData(paint.image as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PrepError(String(localized: "couldn't read the 3D model's colours", bundle: .mimicCore)) }
        picture = try Engine.rgba(image, opaque: true); width = image.width; height = image.height
        self.model = model; uv = paint.uv
        grid = Nearest(model)
        toModel = toPrint.inverse
        // Its height as placed, in millimetres, then in the model's units: placing turns it and
        // scales it the same every way, by the cube root of how much it grows a volume.
        var lo = Double.infinity, hi = -lo
        for p in model.positions {
            let z = (toPrint * SIMD4(SIMD3<Double>(p), 1)).z
            lo = min(lo, z); hi = max(hi, z)
        }
        let grows: Double = cbrt(abs(simd_determinant(toPrint)))
        let height: Double = hi - lo
        self.far = Float(Double(far) * height / grows)
        reach = min(self.far, Float(Self.reachCap / grows))
    }

    /// How far `colour(at:along:)` looks each way, in the model's units: as far as the nearest
    /// point does, but no more than `reachCap`.
    let reach: Float
    /// Millimetres. The line has to cross print prep's push (--inflate, 0.16 mm on a 0.4 nozzle,
    /// 0.24 mm on a 0.6) and what the tabletop's trim moves the surface: on a 28 mm Lorelei a
    /// line reaching 1 mm found the model for all but her base and a few edges. Further on a big
    /// mini, it could find a neighbouring part instead.
    static let reachCap = 2.0

    /// The colours of `mini`, or nil when the engine painted it grey (`Tabletop.inColour`) or
    /// left it unpainted.
    public static func of(_ mini: Mini) throws -> EngineColours? {
        guard Tabletop.inColour(mini.settings), let stl = mini.stl else { return nil }
        let glb = mini.folder.appendingPathComponent(Mini.modelFile)
        let read = try GLB.read(painted: glb)
        guard let paint = read.paint else { return nil }
        // Prepped before print prep kept a record: placed again, as prep places it now, in about a
        // second. At the sizes the print file was made at: a resize that failed or was stopped
        // left the new ones asked for beside the old print file.
        let toPrint = try Placement.read(mini.folder) ?? {
            var placed = read.mesh, made = mini.settings
            made.requested = made.made ?? made.requested
            return try Prep.place(&placed, PrepOptions.parse([glb.path, stl.path] + Pipeline.prepFlags(made))).toPrint
        }()
        return try EngineColours(model: read.mesh, paint: paint, toPrint: toPrint)
    }

    /// The colour at `p` on the print file (millimetres), as red, green and blue; nil where the
    /// model isn't near (the base).
    public func colour(at p: SIMD3<Float>) -> SIMD3<UInt8>? {
        let q = toModel * SIMD4(SIMD3<Double>(p), 1)
        guard let hit = grid.nearest(SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z)), within: far) else { return nil }
        return colour(hit.triangle, hit.weights)
    }

    /// The colour under the print file's surface at `p`, where the line through it along the
    /// surface's `normal` meets the model nearest `p`, within `reach` either way; else the nearest
    /// point's (`colour(at:)`). Print prep pushed the surface out (--inflate) and the tabletop's
    /// trim moved it, so beside a raised strand or cord the nearest point is the strand's edge:
    /// nearest point alone widened each by the push on both sides, and smeared faces. Either way
    /// along the line, so it doesn't matter which way the normal points.
    public func colour(at p: SIMD3<Float>, along normal: SIMD3<Float>) -> SIMD3<UInt8>? {
        let q4 = toModel * SIMD4(SIMD3<Double>(p), 1), n4 = toModel * SIMD4(SIMD3<Double>(normal), 0)
        let q = SIMD3<Float>(Float(q4.x), Float(q4.y), Float(q4.z))
        let dir = simd_normalize(SIMD3<Float>(Float(n4.x), Float(n4.y), Float(n4.z)))
        guard dir.x.isFinite else { return colour(at: p) }
        let from = q + dir * reach
        var best: (off: Float, triangle: Int, weights: SIMD3<Float>)?
        grid.cells(from: from, to: q - dir * reach) { i in
            for k in grid.start[i]..<grid.start[i + 1] {
                let n = Int(grid.items[Int(k)]), t = model.triangles[n]
                guard let hit = Self.crossing(from, -dir, model.positions[Int(t.x)], model.positions[Int(t.y)], model.positions[Int(t.z)]),
                      hit.t <= 2 * reach, abs(hit.t - reach) < best?.off ?? .infinity else { continue }
                best = (abs(hit.t - reach), n, hit.weights)
            }
        }
        guard let best else { return colour(at: p) }
        return colour(best.triangle, best.weights)
    }

    /// The picture's colour at a point on the model's triangle, given by its corners' weights.
    func colour(_ triangle: Int, _ weights: SIMD3<Float>) -> SIMD3<UInt8> {
        let t = model.triangles[triangle]
        let place = uv[Int(t.x)] * weights.x + uv[Int(t.y)] * weights.y + uv[Int(t.z)] * weights.z
        // glTF's pictures start at the top left, as the pixels do. Wrapped round, as glTF's default
        // sampler (the engine's, `{}`) repeats a picture.
        let u = place - place.rounded(.down)
        let x = min(Int(u.x * Float(width)), width - 1), y = min(Int(u.y * Float(height)), height - 1)
        let o = 4 * (y * width + x)
        return SIMD3(picture[o], picture[o + 1], picture[o + 2])
    }

    /// The nearest point on a mesh's surface, found through a grid of cells about two triangles
    /// wide, each listing the triangles that reach into it.
    /// ponytail: a uniform grid, capped at 256 cells a side; a BVH if a model's triangles vary
    /// so much in size that one cell holds thousands.
    struct Nearest: Sendable {
        let mesh: Mesh, lo: SIMD3<Float>, cell: Float, dims: SIMD3<Int32>
        var start: [Int32] = [], items: [Int32] = []

        init(_ mesh: Mesh) {
            self.mesh = mesh
            let b = mesh.bounds
            var edges: Float = 0
            for t in mesh.triangles { edges += simd_distance(mesh.positions[Int(t.x)], mesh.positions[Int(t.y)]) }
            let span = b.hi - b.lo
            // Two edges wide, but no more than 256 cells along any side.
            cell = max(2 * edges / Float(max(1, mesh.triangles.count)), span.max() / 256, 1e-6)
            lo = b.lo
            dims = SIMD3<Int32>((span / cell).rounded(.down)) &+ 1
            let cells = Int(dims.x) * Int(dims.y) * Int(dims.z)
            func range(_ t: SIMD3<UInt32>) -> (SIMD3<Int32>, SIMD3<Int32>) {
                let a = mesh.positions[Int(t.x)], b = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
                return (key(simd_min(simd_min(a, b), c)), key(simd_max(simd_max(a, b), c)))
            }
            var count = [Int32](repeating: 0, count: cells + 1)
            for t in mesh.triangles {
                let (l, h) = range(t)
                for z in l.z...h.z { for y in l.y...h.y { for x in l.x...h.x { count[index(SIMD3(x, y, z))] += 1 } } }
            }
            start = [Int32](repeating: 0, count: cells + 1)
            for i in 0..<cells { start[i + 1] = start[i] + count[i] }
            items = [Int32](repeating: 0, count: Int(start[cells]))
            var fill = Array(start.dropLast())
            for (n, t) in mesh.triangles.enumerated() {
                let (l, h) = range(t)
                for z in l.z...h.z { for y in l.y...h.y { for x in l.x...h.x {
                    let i = index(SIMD3(x, y, z))
                    items[Int(fill[i])] = Int32(n); fill[i] += 1
                } } }
            }
        }

        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            simd_clamp(SIMD3<Int32>(((p - lo) / cell).rounded(.down)), .zero, dims &- 1)
        }
        func index(_ k: SIMD3<Int32>) -> Int { Int(k.x) + Int(dims.x) * (Int(k.y) + Int(dims.y) * Int(k.z)) }

        /// The nearest triangle within `within` of `p`, and where on it: its corners' weights.
        func nearest(_ p: SIMD3<Float>, within: Float) -> (triangle: Int, weights: SIMD3<Float>)? {
            let c = SIMD3<Int32>(((p - lo) / cell).rounded(.down))
            var best = within * within, found: (Int, SIMD3<Float>)?
            let reach = Int32((within / cell).rounded(.up)) + 1
            for r in 0...reach {
                // Cells r away and beyond are at least (r - 1) cells from p: done once one's nearer.
                if found != nil, Float(r - 1) * cell >= best.squareRoot() { break }
                for z in (c.z - r)...(c.z + r) { for y in (c.y - r)...(c.y + r) { for x in (c.x - r)...(c.x + r) {
                    guard max(abs(x - c.x), abs(y - c.y), abs(z - c.z)) == r,  // this ring only
                          x >= 0, y >= 0, z >= 0, x < dims.x, y < dims.y, z < dims.z else { continue }
                    let i = index(SIMD3(x, y, z))
                    for k in start[i]..<start[i + 1] {
                        let n = Int(items[Int(k)]), t = mesh.triangles[n]
                        let hit = EngineColours.closest(p, mesh.positions[Int(t.x)], mesh.positions[Int(t.y)], mesh.positions[Int(t.z)])
                        if hit.d2 < best { best = hit.d2; found = (n, hit.weights) }
                    }
                } } }
            }
            return found.map { (triangle: $0.0, weights: $0.1) }
        }

        /// Each cell the segment from `a` to `b` passes through, in order (Amanatides and Woo's
        /// walk): a triangle it crosses is listed in the cell it crosses it in.
        func cells(from a: SIMD3<Float>, to b: SIMD3<Float>, _ body: (Int) -> Void) {
            let ga = (a - lo) / cell, gb = (b - lo) / cell, d = gb - ga
            var at = SIMD3<Int32>(ga.rounded(.down))
            let end = SIMD3<Int32>(gb.rounded(.down))
            // Per axis: which way, and how far along the segment (0 to 1) the next cell wall and each one after it are.
            var step = SIMD3<Int32>.zero, next = SIMD3<Float>(repeating: .infinity), apart = next
            for i in 0..<3 where d[i] != 0 {
                step[i] = d[i] > 0 ? 1 : -1
                apart[i] = abs(1 / d[i])
                next[i] = (d[i] > 0 ? Float(at[i]) + 1 - ga[i] : ga[i] - Float(at[i])) * apart[i]
            }
            while true {
                if all(at .>= .zero) && all(at .< dims) { body(index(at)) }
                let i = next.x < next.y ? (next.x < next.z ? 0 : 2) : (next.y < next.z ? 1 : 2)
                if at == end || next[i] > 1 { return }
                at[i] += step[i]; next[i] += apart[i]
            }
        }
    }

    /// The point of triangle abc nearest p, as its corners' weights, and its squared distance
    /// (Ericson, Real-Time Collision Detection 5.1.5, as `Solid.distance2`).
    static func closest(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (d2: Float, weights: SIMD3<Float>) {
        func at(_ w: SIMD3<Float>) -> (Float, SIMD3<Float>) { (simd_length_squared(p - (a * w.x + b * w.y + c * w.z)), w) }
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return at([1, 0, 0]) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return at([0, 1, 0]) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return at([1 - v, v, 0]) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return at([0, 0, 1]) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return at([1 - w, 0, w]) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6)); return at([0, 1 - w, w])
        }
        let denom = 1 / (va + vb + vc), v = vb * denom, w = vc * denom
        return at([1 - v - w, v, w])
    }

    /// Where the ray from `o` along `dir` (unit) crosses triangle abc from either side: how far
    /// along, and the corners' weights there (Möller and Trumbore).
    static func crossing(_ o: SIMD3<Float>, _ dir: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (t: Float, weights: SIMD3<Float>)? {
        let ab = b - a, ac = c - a, p = simd_cross(dir, ac), det = simd_dot(ab, p)
        guard abs(det) > 1e-12 else { return nil }  // edge on
        let ao = o - a, u = simd_dot(ao, p) / det
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(ao, ab), v = simd_dot(dir, q) / det
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(ac, q) / det
        return t >= 0 ? (t, [1 - u - v, u, v]) : nil
    }
}
