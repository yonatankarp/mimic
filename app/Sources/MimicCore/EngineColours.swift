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
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PrepError("couldn't read the 3D model's colours") }
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
    }

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
        let t = model.triangles[hit.triangle]
        let place = uv[Int(t.x)] * hit.weights.x + uv[Int(t.y)] * hit.weights.y + uv[Int(t.z)] * hit.weights.z
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
}
