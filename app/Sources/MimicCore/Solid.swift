import Foundation
import simd

/// Turns triangles into one watertight solid: a signed distance field sampled on a grid, then a
/// surface drawn through it. This is what Blender's voxel remesh did, done in slabs so memory
/// follows the surface, not the volume: a 100 mm figure at 0.1 mm is ~10⁹ grid points, which is
/// where Blender reached 14 GB.
///
/// The field at a point is its distance to the nearest triangle (exact, but only computed near
/// the surface), negative inside. Inside is decided by winding: a ray up each grid column counts
/// the surfaces it enters and leaves, so overlapping pieces union instead of cancelling out,
/// and a mesh turned inside out still reads as solid.
struct Solid {
    struct Base { var radius: Float, height: Float, bevel: Float }

    /// Grid points are origin + (i, j, k) × h.
    let origin: SIMD3<Float>
    let h: Float
    let nx: Int, ny: Int, nz: Int
    /// Surface offset: the extracted surface lies this far outside the triangles.
    let inflate: Float
    let base: Base?
    /// Everything below this z is cut away.
    let cut: Float?

    /// Grid for `mesh` plus the base, padded so every boundary sample is outside. With a cut, a
    /// grid plane sits half a voxel either side of it, so the flat bottom comes out exactly flat.
    init(mesh: Mesh, voxel: Float, inflate: Float, base: Base?, cut: Float?) {
        var (lo, hi) = mesh.bounds
        if let base {
            lo = simd_min(lo, SIMD3(-base.radius, -base.radius, 0))
            hi = simd_max(hi, SIMD3(base.radius, base.radius, base.height))
        }
        let pad = inflate + 2 * voxel
        lo -= pad; hi += pad
        if let cut { lo.z = cut - voxel / 2 }
        self.origin = lo; self.h = voxel; self.inflate = inflate; self.base = base; self.cut = cut
        nx = Int(((hi.x - lo.x) / voxel).rounded(.up)) + 1
        ny = Int(((hi.y - lo.y) / voxel).rounded(.up)) + 1
        nz = max(2, Int(((hi.z - lo.z) / voxel).rounded(.up)) + 1)
    }

    // MARK: Inside or outside

    /// Per grid column (i + j·nx), the z intervals inside the solid, as [enter, leave] pairs.
    struct Columns {
        var start: [Int32]
        var z: [Float]
    }

    func columns(_ mesh: Mesh) -> Columns {
        struct Hit { var column: Int32; var z: Float; var up: Int8 }
        var hits: [Hit] = []
        hits.reserveCapacity(mesh.triangles.count * 2)
        let ox = Double(origin.x), oy = Double(origin.y), hd = Double(h)
        for t in mesh.triangles {
            var a = mesh.positions[Int(t.x)], b = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
            let area = Self.edge(a, b, Double(c.x), Double(c.y))
            if area == 0 { continue }  // seen edge-on from below: no column enters through it
            // Faces pointing down are where a ray going up enters the solid.
            let up: Int8 = area > 0 ? -1 : 1
            if area < 0 { swap(&b, &c) }
            let i0 = max(0, Int(((Double(min(a.x, b.x, c.x)) - ox) / hd).rounded(.up)))
            let i1 = min(nx - 1, Int(((Double(max(a.x, b.x, c.x)) - ox) / hd).rounded(.down)))
            let j0 = max(0, Int(((Double(min(a.y, b.y, c.y)) - oy) / hd).rounded(.up)))
            let j1 = min(ny - 1, Int(((Double(max(a.y, b.y, c.y)) - oy) / hd).rounded(.down)))
            if i0 > i1 || j0 > j1 { continue }
            let total = abs(area)
            for j in j0...j1 {
                let py = oy + Double(j) * hd
                for i in i0...i1 {
                    let px = ox + Double(i) * hd
                    let w0 = Self.edge(b, c, px, py), w1 = Self.edge(c, a, px, py), w2 = Self.edge(a, b, px, py)
                    guard Self.covers(w0, b, c), Self.covers(w1, c, a), Self.covers(w2, a, b) else { continue }
                    let z = (w0 * Double(a.z) + w1 * Double(b.z) + w2 * Double(c.z)) / total
                    hits.append(Hit(column: Int32(i + j * nx), z: Float(z), up: up))
                }
            }
        }
        // Group by column (counting sort), then walk each column bottom to top.
        var count = [Int32](repeating: 0, count: nx * ny + 1)
        for hit in hits { count[Int(hit.column) + 1] += 1 }
        for i in 1..<count.count { count[i] += count[i - 1] }
        var sorted = [Hit](repeating: Hit(column: 0, z: 0, up: 0), count: hits.count)
        var fill = count
        for hit in hits { sorted[Int(fill[Int(hit.column)])] = hit; fill[Int(hit.column)] += 1 }
        hits = []
        var start = [Int32](repeating: 0, count: nx * ny + 1)
        var zs: [Float] = []
        for col in 0..<(nx * ny) {
            let range = Int(count[col])..<Int(count[col + 1])
            if !range.isEmpty {
                sorted[range].sort { $0.z < $1.z }
                var winding = 0, entered: Float = 0
                for hit in sorted[range] {
                    let was = winding
                    winding += Int(hit.up)
                    if was == 0 && winding != 0 { entered = hit.z }
                    if was != 0 && winding == 0 { zs.append(entered); zs.append(hit.z) }
                }
                // Still inside at the top: a hole let the ray out unseen. The column stays
                // outside there rather than growing a spike to the sky.
            }
            start[col + 1] = Int32(zs.count)
        }
        return Columns(start: start, z: zs)
    }

    /// Twice the signed area of (a, b, p) in x/y. The same edge seen from its two triangles gives
    /// exactly opposite values (endpoints always taken in one order), so a column through a
    /// shared edge is counted by exactly one of them, never both or neither.
    static func edge(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ px: Double, _ py: Double) -> Double {
        let (p, q, s) = (a.x, a.y) < (b.x, b.y) ? (a, b, 1.0) : (b, a, -1.0)
        return s * ((Double(q.x) - Double(p.x)) * (py - Double(p.y)) - (Double(q.y) - Double(p.y)) * (px - Double(p.x)))
    }

    /// Inside the edge, or on it and it's a "top-left" edge: the rasteriser's rule that shares
    /// every point on an edge to exactly one of the two triangles.
    static func covers(_ w: Double, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
        if w != 0 { return w > 0 }
        let d = b - a
        return d.y > 0 || (d.y == 0 && d.x < 0)
    }

    // MARK: The field

    /// The base: a cylinder standing on z = 0 with its top edge rounded like a commercial base.
    func baseDistance(_ p: SIMD3<Float>, _ b: Base) -> Float {
        let rho = (p.x * p.x + p.y * p.y).squareRoot()
        let a = rho - (b.radius - b.bevel), c = p.z - (b.height - b.bevel)
        if a > 0 && c > 0 { return (a * a + c * c).squareRoot() - b.bevel }
        let side = rho - b.radius, vertical = max(p.z - b.height, -p.z)
        if side > 0 && vertical > 0 { return (side * side + vertical * vertical).squareRoot() }
        return max(side, vertical)
    }

    /// Squared distance from p to triangle abc (Ericson, Real-Time Collision Detection 5.1.5).
    @inline(__always)
    static func distance2(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(ap) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { return simd_length_squared(ap - ab * (d1 / (d1 - d3))) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { return simd_length_squared(ap - ac * (d2 / (d2 - d6))) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return simd_length_squared(bp - (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))
        }
        let denom = 1 / (va + vb + vc)
        return simd_length_squared(ap - ab * (vb * denom) - ac * (vc * denom))
    }

    // MARK: Surface

    /// The surface of the solid: every grid slab computed in parallel, stitched into one mesh.
    func surface(_ mesh: Mesh) -> Mesh {
        let cols = columns(mesh)
        let slab = 8
        let slabs = (nz - 1 + slab - 1) / slab
        // Only points this close to a triangle need their distance: any grid edge the surface
        // crosses has both ends within inflate + one voxel of the triangles.
        let band = inflate + 1.1 * h

        // Which triangles each slab needs: those within `band` of its z range.
        var count = [Int](repeating: 0, count: slabs + 1)
        var span = [(Int32, Int32)](repeating: (0, -1), count: mesh.triangles.count)
        for (n, t) in mesh.triangles.enumerated() {
            let zs = [mesh.positions[Int(t.x)].z, mesh.positions[Int(t.y)].z, mesh.positions[Int(t.z)].z]
            let lo = Int(((zs.min()! - band - origin.z) / (h * Float(slab))).rounded(.down))
            let hi = Int(((zs.max()! + band - origin.z) / (h * Float(slab))).rounded(.down))
            let a = max(0, lo), b = min(slabs - 1, hi)
            if a > b { continue }
            span[n] = (Int32(a), Int32(b))
            for s in a...b { count[s + 1] += 1 }
        }
        for s in 0..<slabs { count[s + 1] += count[s] }
        var members = [Int32](repeating: 0, count: count[slabs])
        var fill = count
        for (n, (a, b)) in span.enumerated() where a <= b {
            for s in Int(a)...Int(b) { members[fill[s]] = Int32(n); fill[s] += 1 }
        }
        span = []

        let parts = Parts(slabs), lists = members, first = count
        DispatchQueue.concurrentPerform(iterations: slabs) { s in
            let k0 = s * slab, k1 = min(k0 + slab, nz - 1)
            let tris = lists[first[s]..<first[s + 1]]
            parts.set(s, extract(k0: k0, k1: k1, triangles: tris, mesh: mesh, columns: cols, band: band))
        }
        return stitch(parts.all)
    }

    final class Parts: @unchecked Sendable {
        private var items: [Part?]
        private let lock = NSLock()
        init(_ n: Int) { items = Array(repeating: nil, count: n) }
        func set(_ i: Int, _ p: Part) { lock.withLock { items[i] = p } }
        var all: [Part] { items.map { $0! } }
    }

    /// One slab's surface. Vertices on its bottom and top grid planes are listed by edge, so the
    /// slabs either side can be joined without seams.
    struct Part {
        var positions: [SIMD3<Float>] = []
        var triangles: [SIMD3<UInt32>] = []
        var bottom: [(key: Int, vertex: UInt32)] = []
        var top: [(key: Int, vertex: UInt32)] = []
    }

    /// The field on grid planes k0...k1, and the surface through the cubes between them.
    func extract(k0: Int, k1: Int, triangles: ArraySlice<Int32>, mesh: Mesh, columns: Columns, band: Float) -> Part {
        let planes = k1 - k0 + 1, layer = nx * ny
        var field = [Float](repeating: band * band, count: layer * planes)
        let hInv = 1 / h
        field.withUnsafeMutableBufferPointer { f in
            for n in triangles {
                let t = mesh.triangles[Int(n)]
                let a = mesh.positions[Int(t.x)], b = mesh.positions[Int(t.y)], c = mesh.positions[Int(t.z)]
                let lo = (simd_min(simd_min(a, b), c) - band - origin) * hInv
                let hi = (simd_max(simd_max(a, b), c) + band - origin) * hInv
                let i0 = max(0, Int(lo.x.rounded(.up))), i1 = min(nx - 1, Int(hi.x.rounded(.down)))
                let j0 = max(0, Int(lo.y.rounded(.up))), j1 = min(ny - 1, Int(hi.y.rounded(.down)))
                let kk0 = max(k0, Int(lo.z.rounded(.up))), kk1 = min(k1, Int(hi.z.rounded(.down)))
                if i0 > i1 || j0 > j1 || kk0 > kk1 { continue }
                var normal = simd_cross(b - a, c - a)
                let len = simd_length(normal)
                let flat = len > 0
                if flat { normal /= len }
                for k in kk0...kk1 {
                    let z = origin.z + Float(k) * h
                    for j in j0...j1 {
                        let y = origin.y + Float(j) * h
                        let row = (k - k0) * layer + j * nx
                        for i in i0...i1 {
                            let p = SIMD3(origin.x + Float(i) * h, y, z)
                            // Most of the box is farther than the band from the triangle's plane.
                            if flat && abs(simd_dot(p - a, normal)) >= band { continue }
                            let d = Self.distance2(p, a, b, c)
                            if d < f[row + i] { f[row + i] = d }
                        }
                    }
                }
            }
        }

        // Distance → signed field: minus inside, less the inflate, joined to the base, cut flat.
        // Never exactly zero, so no surface vertex lands on a grid point, where vertices of
        // neighbouring edges would coincide and weld into a knot in the slicer.
        let tiny = h * 0.01
        for j in 0..<ny {
            for i in 0..<nx {
                let col = i + j * nx
                var at = Int(columns.start[col]); let end = Int(columns.start[col + 1])
                for k in 0...(k1 - k0) {
                    let z = origin.z + Float(k0 + k) * h
                    while at < end && columns.z[at + 1] < z { at += 2 }
                    let inside = at < end && columns.z[at] <= z
                    let d = field[k * layer + col].squareRoot()
                    var v = inside ? -max(d + inflate, tiny) : d - inflate
                    if let base { v = min(v, baseDistance(SIMD3(origin.x + Float(i) * h, origin.y + Float(j) * h, z), base)) }
                    if let cut { v = max(v, cut - z) }
                    if abs(v) < tiny { v = tiny }
                    field[k * layer + col] = v
                }
            }
        }

        return Self.march(field, nx: nx, ny: ny, planes: planes, k0: k0, origin: origin, h: h)
    }

    /// The surface through a block of field values (`planes` grid planes of nx × ny, the first
    /// being grid plane k0): marching cubes with the table below.
    static func march(_ field: [Float], nx: Int, ny: Int, planes: Int, k0: Int, origin: SIMD3<Float>, h: Float) -> Part {
        let layer = nx * ny
        var part = Part()
        // Vertex ids of the crossing on each grid edge: x and y edges on a layer's bottom and top
        // planes, z edges between them. Rolled layer by layer so memory is two planes, not a slab.
        var below = [Int32](repeating: -1, count: 2 * layer), above = below
        var vertical = [Int32](repeating: -1, count: layer)
        let table = CubeTable.shared
        for k in 0..<(planes - 1) {
            for n in above.indices { above[n] = -1 }
            for n in vertical.indices { vertical[n] = -1 }
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    var values = SIMD8<Float>()
                    var cube = 0
                    for c in 0..<8 {
                        let v = field[(k + (c >> 2)) * layer + (j + (c >> 1 & 1)) * nx + i + (c & 1)]
                        values[c] = v
                        if v < 0 { cube |= 1 << c }
                    }
                    if cube == 0 || cube == 255 { continue }
                    var ids = SIMD16<Int32>(repeating: -1)
                    for e in table.crossed[cube] {
                        let e = Int(e)
                        let (a, b) = CubeTable.edges[e]
                        let ci = i + (a & 1), cj = j + (a >> 1 & 1), ck = k + (a >> 2)
                        let axis = (b ^ a) == 1 ? 0 : (b ^ a) == 2 ? 1 : 2
                        let key = ci + cj * nx
                        var id: Int32
                        if axis == 2 { id = vertical[key] } else { id = ck == k ? below[2 * key + axis] : above[2 * key + axis] }
                        if id < 0 {
                            id = Int32(part.positions.count)
                            let t = values[a] / (values[a] - values[b])
                            var p = origin + SIMD3(Float(ci), Float(cj), Float(k0 + ck)) * h
                            p[axis] += t * h
                            part.positions.append(p)
                            if axis == 2 { vertical[key] = id }
                            else if ck == k { below[2 * key + axis] = id } else { above[2 * key + axis] = id }
                            if axis < 2 && ck == 0 { part.bottom.append((2 * key + axis, UInt32(id))) }
                            if axis < 2 && ck == planes - 1 { part.top.append((2 * key + axis, UInt32(id))) }
                        }
                        ids[e] = id
                    }
                    for (n, polygon) in table.centres[cube].enumerated() {
                        var c = SIMD3<Float>()
                        for e in polygon { c += part.positions[Int(ids[Int(e)])] }
                        ids[12 + n] = Int32(part.positions.count)
                        part.positions.append(c / Float(polygon.count))
                    }
                    let tris = table.triangles[cube]
                    for t in stride(from: 0, to: tris.count, by: 3) {
                        part.triangles.append(SIMD3(UInt32(ids[Int(tris[t])]), UInt32(ids[Int(tris[t + 1])]), UInt32(ids[Int(tris[t + 2])])))
                    }
                }
            }
            swap(&below, &above)
        }
        return part
    }

    /// Joins the slabs: a vertex on a slab's top plane is the same point as the one the next
    /// slab made on its bottom plane. The unused copies stay until `largestPiece` compacts.
    func stitch(_ parts: [Part]) -> Mesh {
        var offset = [Int](repeating: 0, count: parts.count + 1)
        for (s, p) in parts.enumerated() { offset[s + 1] = offset[s] + p.positions.count }
        var out = Mesh()
        out.positions.reserveCapacity(offset.last!)
        for p in parts { out.positions += p.positions }
        // Map each top-plane vertex to its twin; unused copies are dropped by the compaction below.
        var remap = Array(0..<UInt32(offset.last!))
        for s in 0..<(parts.count - 1) {
            var twin: [Int: UInt32] = [:]
            for (key, v) in parts[s + 1].bottom { twin[key] = UInt32(offset[s + 1]) + v }
            for (key, v) in parts[s].top {
                if let t = twin[key] { remap[offset[s] + Int(v)] = t }
            }
        }
        for (s, p) in parts.enumerated() {
            let o = UInt32(offset[s])
            for t in p.triangles {
                out.triangles.append(SIMD3(remap[Int(t.x + o)], remap[Int(t.y + o)], remap[Int(t.z + o)]))
            }
        }
        return out
    }
}

extension Mesh {
    /// Drops vertices no triangle uses and renumbers the rest.
    func compacted() -> Mesh {
        var index = [UInt32](repeating: .max, count: positions.count)
        var out = Mesh()
        out.triangles.reserveCapacity(triangles.count)
        for t in triangles {
            var n = SIMD3<UInt32>()
            for c in 0..<3 {
                let v = Int(t[c])
                if index[v] == .max { index[v] = UInt32(out.positions.count); out.positions.append(positions[v]) }
                n[c] = index[v]
            }
            out.triangles.append(n)
        }
        return out
    }

    /// The largest connected piece (by vertex count, as Blender's "separate by loose parts"
    /// sorted it), and how many others were dropped.
    func largestPiece() -> (Mesh, dropped: Int) {
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
        var used = [Bool](repeating: false, count: positions.count)
        for t in triangles { used[Int(t.x)] = true; used[Int(t.y)] = true; used[Int(t.z)] = true }
        var size: [Int32: Int] = [:]
        for v in 0..<Int32(positions.count) where used[Int(v)] { size[find(v), default: 0] += 1 }
        guard let keep = size.max(by: { $0.value < $1.value })?.key else { return (self, 0) }
        let kept = Mesh(positions: positions, triangles: triangles.filter { find(Int32($0.x)) == keep }).compacted()
        return (kept, size.count - 1)
    }
}

/// Which triangles to draw in a grid cube, for each of the 256 ways its corners can be inside
/// or outside. Generated rather than copied: the classic table joins or separates the inside
/// corners of an ambiguous face differently in neighbouring cubes, which leaves holes. Here
/// every face decides by its own four corners alone (inside corners always kept apart), so the
/// two cubes sharing a face always agree, and the surface is closed and manifold by construction.
struct CubeTable: Sendable {
    /// Corner c sits at (c & 1, c >> 1 & 1, c >> 2). Edges join corners one bit apart, lower first.
    static let edges: [(Int, Int)] = {
        var e: [(Int, Int)] = []
        for a in 0..<8 { for bit in [1, 2, 4] where a & bit == 0 { e.append((a, a | bit)) } }
        return e
    }()

    /// Per case: the edges the surface crosses.
    let crossed: [[UInt8]]
    /// Per case: three vertices per triangle, wound counter-clockwise seen from outside. 0-11
    /// are the crossings on those edges; 12 + n is the centre of polygon `centres[n]`.
    let triangles: [[UInt8]]
    let centres: [[[UInt8]]]

    static let shared = CubeTable()

    init() {
        var edgeOf: [Int: Int] = [:]
        for (n, (a, b)) in Self.edges.enumerated() { edgeOf[a * 8 + b] = n; edgeOf[b * 8 + a] = n }
        // The two faces each edge lies on, as axis * 2 + side.
        let facesOf: [Set<Int>] = Self.edges.map { a, b in
            Set((0..<3).filter { (a ^ b) >> $0 & 1 == 0 }.map { $0 * 2 + (a >> $0 & 1) })
        }
        // Each face's corners, counter-clockwise seen from outside the cube.
        var faces: [[Int]] = []
        for axis in 0..<3 {
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            for side in 0..<2 {
                let ring = [(0, 0), (1, 0), (1, 1), (0, 1)].map { side << axis | $0.0 << u | $0.1 << v }
                faces.append(side == 1 ? ring : ring.reversed())
            }
        }
        var table: [[UInt8]] = [], used: [[UInt8]] = [], polygons: [[[UInt8]]] = []
        for cube in 0..<256 {
            let inside = { (c: Int) in cube >> c & 1 == 1 }
            // Walking each face's rim, the surface leaves the inside region at an "exit" and
            // comes back at an "entry"; joining each exit to the entry before it cuts off the
            // inside corners one by one. Every crossing is an exit on one of its two faces and
            // an entry on the other, so following the joins closes into polygons.
            var next = [Int](repeating: -1, count: 12)
            for face in faces {
                var crossings: [(edge: Int, exit: Bool)] = []
                for n in 0..<4 where inside(face[n]) != inside(face[(n + 1) % 4]) {
                    crossings.append((edgeOf[face[n] * 8 + face[(n + 1) % 4]]!, inside(face[n])))
                }
                for (n, c) in crossings.enumerated() where c.exit {
                    next[c.edge] = crossings[(n + crossings.count - 1) % crossings.count].edge
                }
            }
            var seen = Set<Int>(), tris: [UInt8] = [], middles: [[UInt8]] = []
            for e in 0..<12 where next[e] >= 0 && !seen.contains(e) {
                var polygon = [e], x = next[e]
                seen.insert(e)
                while x != e { polygon.append(x); seen.insert(x); x = next[x] }
                // A fan from a corner whose diagonals all run through the cube. A diagonal lying
                // on a face would be drawn by the neighbouring cube too: an edge of four triangles.
                let apex = polygon.indices.first { a in
                    (2..<(polygon.count - 1)).allSatisfy { facesOf[polygon[a]].isDisjoint(with: facesOf[polygon[(a + $0) % polygon.count]]) }
                }
                if let apex {
                    let p = polygon[apex...] + polygon[..<apex]
                    for n in 1..<(p.count - 1) { tris += [UInt8(p[p.startIndex]), UInt8(p[p.startIndex + n]), UInt8(p[p.startIndex + n + 1])] }
                } else {
                    // No such corner (a tunnel through the cube): fan from the polygon's centre.
                    let centre = UInt8(12 + middles.count)
                    middles.append(polygon.map(UInt8.init))
                    for n in polygon.indices { tris += [centre, UInt8(polygon[n]), UInt8(polygon[(n + 1) % polygon.count])] }
                }
            }
            table.append(tris)
            used.append((0..<12).filter { next[$0] >= 0 }.map(UInt8.init))
            polygons.append(middles)
        }
        // Wind them to face outward: with only corner 0 inside, the normal points away from it.
        func mid(_ e: UInt8) -> SIMD3<Float> {
            let (a, b) = Self.edges[Int(e)]
            let p = { (c: Int) in SIMD3(Float(c & 1), Float(c >> 1 & 1), Float(c >> 2)) }
            return (p(a) + p(b)) / 2
        }
        let t = table[1]
        let normal: SIMD3<Float> = simd_cross(mid(t[1]) - mid(t[0]), mid(t[2]) - mid(t[0]))
        if simd_dot(normal, SIMD3<Float>(1, 1, 1)) < 0 {
            // Written out step by step: Swift 6.3's type checker gives up on the one-line version.
            table = table.map { (tris: [UInt8]) -> [UInt8] in
                var flipped: [UInt8] = []
                for i in stride(from: 0, to: tris.count, by: 3) { flipped += [tris[i], tris[i + 2], tris[i + 1]] }
                return flipped
            }
        }
        crossed = used
        centres = polygons
        triangles = table
    }
}
