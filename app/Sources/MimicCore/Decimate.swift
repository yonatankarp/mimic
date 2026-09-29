import simd

/// Trims a closed mesh to about `target` triangles by collapsing its cheapest edges first, where
/// cheap means the surface moves least (Garland and Heckbert's quadric error). Swept in rounds
/// with a rising error threshold rather than a priority queue, as in Sven Forstmann's fast
/// simplification: seconds for millions of triangles, and about the same result.
///
/// A collapse that would fold a triangle over, or join two sheets that only pass close by (the
/// edge's ends sharing a neighbour other than its two triangles' third corners), is skipped:
/// either would leave the print file with edges that aren't between exactly two triangles.
struct Decimate {
    struct Quadric {
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0, e = 0.0, f = 0.0, g = 0.0, h = 0.0, i = 0.0, j = 0.0

        init() {}
        /// The squared distance to the plane n·x + w = 0.
        init(_ n: SIMD3<Double>, _ w: Double) {
            a = n.x * n.x; b = n.x * n.y; c = n.x * n.z; d = n.x * w
            e = n.y * n.y; f = n.y * n.z; g = n.y * w
            h = n.z * n.z; i = n.z * w; j = w * w
        }
        static func + (l: Quadric, r: Quadric) -> Quadric {
            var q = Quadric()
            q.a = l.a + r.a; q.b = l.b + r.b; q.c = l.c + r.c; q.d = l.d + r.d; q.e = l.e + r.e
            q.f = l.f + r.f; q.g = l.g + r.g; q.h = l.h + r.h; q.i = l.i + r.i; q.j = l.j + r.j
            return q
        }
        func error(_ p: SIMD3<Double>) -> Double {
            a * p.x * p.x + 2 * b * p.x * p.y + 2 * c * p.x * p.z + 2 * d * p.x
                + e * p.y * p.y + 2 * f * p.y * p.z + 2 * g * p.y + h * p.z * p.z + 2 * i * p.z + j
        }
        /// The point of least error, when there is a single one.
        func minimum() -> SIMD3<Double>? {
            let m = simd_double3x3(SIMD3(a, b, c), SIMD3(b, e, f), SIMD3(c, f, h))  // symmetric
            let det = m.determinant, scale = (a + e + h) / 3
            // Flat or evenly curved in some direction: no single best point, and a near-zero
            // determinant would throw the vertex far along the surface.
            guard scale > 0, abs(det) > 1e-9 * scale * scale * scale else { return nil }
            return m.inverse * SIMD3(-d, -g, -i)
        }
    }

    var pos: [SIMD3<Float>]
    var q: [Quadric]
    var tri: [SIMD3<Int32>]
    var err: [SIMD4<Float>]  // per edge, and the least of the three
    var gone: [Bool]
    var dirty: [Bool]
    // Each vertex's triangles: refs[start ..< start + count], entries tid * 4 + corner.
    var start: [Int32]
    var count: [Int32]
    var refs: [Int32] = []
    var alive: Int
    var ring0: [Int32] = [], ring1: [Int32] = []
    var dying0: [Bool] = [], dying1: [Bool] = []

    static func run(_ mesh: consuming Mesh, target: Int) -> Mesh {
        var d = Decimate(mesh)
        d.simplify(target)
        var out = Mesh(positions: d.pos, triangles: [])
        out.triangles.reserveCapacity(d.alive)
        for n in d.tri.indices where !d.gone[n] { out.triangles.append(SIMD3<UInt32>(truncatingIfNeeded: d.tri[n])) }
        return out.compacted()
    }

    init(_ mesh: consuming Mesh) {
        pos = mesh.positions
        tri = mesh.triangles.map { SIMD3<Int32>(truncatingIfNeeded: $0) }
        q = [Quadric](repeating: Quadric(), count: pos.count)
        err = [SIMD4<Float>](repeating: .zero, count: tri.count)
        gone = [Bool](repeating: false, count: tri.count)
        dirty = gone
        start = [Int32](repeating: 0, count: pos.count)
        count = start
        alive = tri.count
        for t in tri {
            let p0 = SIMD3<Double>(pos[Int(t.x)]), p1 = SIMD3<Double>(pos[Int(t.y)]), p2 = SIMD3<Double>(pos[Int(t.z)])
            var n = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(n)
            if len > 0 { n /= len }
            let plane = Quadric(n, -simd_dot(n, p0))
            q[Int(t.x)] = q[Int(t.x)] + plane; q[Int(t.y)] = q[Int(t.y)] + plane; q[Int(t.z)] = q[Int(t.z)] + plane
        }
    }

    func edgeCost(_ v0: Int32, _ v1: Int32) -> (Float, SIMD3<Float>) {
        let qq = q[Int(v0)] + q[Int(v1)]
        let a = SIMD3<Double>(pos[Int(v0)]), b = SIMD3<Double>(pos[Int(v1)]), mid = (a + b) / 2
        if let p = qq.minimum(), simd_distance(p, mid) <= simd_distance(a, b) { return (Float(qq.error(p)), SIMD3<Float>(p)) }
        let em = qq.error(mid), ea = qq.error(a), eb = qq.error(b)
        if em <= ea && em <= eb { return (Float(em), SIMD3<Float>(mid)) }
        return ea <= eb ? (Float(ea), pos[Int(v0)]) : (Float(eb), pos[Int(v1)])
    }

    mutating func errors(_ n: Int) {
        let t = tri[n]
        let e0 = edgeCost(t.x, t.y).0, e1 = edgeCost(t.y, t.z).0, e2 = edgeCost(t.z, t.x).0
        err[n] = SIMD4(e0, e1, e2, min(e0, e1, e2))
    }

    /// Drops dead triangles and rebuilds each vertex's list of triangles.
    mutating func compact() {
        var keep = 0
        for n in tri.indices where !gone[n] { tri[keep] = tri[n]; err[keep] = err[n]; keep += 1 }
        tri.removeLast(tri.count - keep); err.removeLast(err.count - keep)
        gone = [Bool](repeating: false, count: keep); dirty = gone
        for v in count.indices { count[v] = 0 }
        for t in tri { count[Int(t.x)] += 1; count[Int(t.y)] += 1; count[Int(t.z)] += 1 }
        var s: Int32 = 0
        for v in count.indices { start[v] = s; s += count[v]; count[v] = 0 }
        refs = [Int32](repeating: 0, count: Int(s))
        for (n, t) in tri.enumerated() {
            for c in 0..<3 {
                let v = Int(t[c])
                refs[Int(start[v] + count[v])] = Int32(n) * 4 + Int32(c)
                count[v] += 1
            }
        }
    }

    /// Would moving v to p fold one of its triangles over or make it a sliver? Marks the
    /// triangles that also hold `other`: those vanish with the collapse.
    func folds(_ v: Int32, _ other: Int32, _ p: SIMD3<Float>, _ dying: inout [Bool]) -> Bool {
        let s = Int(start[Int(v)])
        for k in 0..<Int(count[Int(v)]) {
            let r = refs[s + k], n = Int(r >> 2), c = Int(r & 3)
            dying[k] = false
            if gone[n] { continue }
            let t = tri[n]
            let a = t[(c + 1) % 3], b = t[(c + 2) % 3]
            if a == other || b == other { dying[k] = true; continue }
            let pa = pos[Int(a)], pb = pos[Int(b)]
            let d1 = simd_normalize(pa - p), d2 = simd_normalize(pb - p)
            if abs(simd_dot(d1, d2)) > 0.999 { return true }
            let before = simd_cross(pa - pos[Int(v)], pb - pos[Int(v)])
            if simd_dot(simd_normalize(simd_cross(d1, d2)), simd_normalize(before)) < 0.2 { return true }
        }
        return false
    }

    /// The edge's ends may share only the two corners opposite it; a third shared neighbour
    /// means the collapse would pinch two sheets together.
    mutating func linkOK(_ v0: Int32, _ v1: Int32) -> Bool {
        var r0: [Int32] = [], r1: [Int32] = []
        swap(&r0, &ring0); swap(&r1, &ring1)  // reuse their storage
        ring(v0, &r0); ring(v1, &r1)
        var shared = 0
        for a in r0 where a != v1 && r1.contains(a) { shared += 1 }
        swap(&r0, &ring0); swap(&r1, &ring1)
        return shared == 2
    }

    func ring(_ v: Int32, _ out: inout [Int32]) {
        out.removeAll(keepingCapacity: true)
        let s = Int(start[Int(v)])
        for k in 0..<Int(count[Int(v)]) {
            let n = Int(refs[s + k] >> 2)
            if gone[n] { continue }
            let t = tri[n]
            for c in 0..<3 where t[c] != v && !out.contains(t[c]) { out.append(t[c]) }
        }
    }

    mutating func moveTriangles(of v: Int32, to v0: Int32, _ dying: [Bool]) {
        let s = Int(start[Int(v)])
        for k in 0..<Int(count[Int(v)]) {
            let r = refs[s + k], n = Int(r >> 2), c = Int(r & 3)
            if gone[n] { continue }
            if dying[k] { gone[n] = true; alive -= 1; continue }
            tri[n][c] = v0
            dirty[n] = true
            errors(n)
            refs.append(r)
        }
    }

    mutating func simplify(_ target: Int) {
        for round in 0..<200 where alive > target {
            if round % 5 == 0 {
                compact()
                if round == 0 { for n in tri.indices { errors(n) } }
            }
            for n in dirty.indices { dirty[n] = false }
            // Rounds sweep everything under a threshold that rises steeply, so the cheapest
            // collapses happen first across the whole mesh.
            let threshold = Float(1e-9 * pow(Double(round + 3), 7))
            for n in tri.indices {
                if alive <= target { break }
                if gone[n] || dirty[n] || err[n][3] > threshold { continue }
                for j in 0..<3 where err[n][j] <= threshold {
                    let v0 = tri[n][j], v1 = tri[n][(j + 1) % 3]
                    let p = edgeCost(v0, v1).1
                    let c0 = Int(count[Int(v0)]), c1 = Int(count[Int(v1)])
                    if dying0.count < c0 { dying0 = [Bool](repeating: false, count: c0 * 2) }
                    if dying1.count < c1 { dying1 = [Bool](repeating: false, count: c1 * 2) }
                    var d0: [Bool] = [], d1: [Bool] = []
                    swap(&d0, &dying0); swap(&d1, &dying1)
                    let blocked = folds(v0, v1, p, &d0) || folds(v1, v0, p, &d1)
                    swap(&d0, &dying0); swap(&d1, &dying1)
                    if blocked || !linkOK(v0, v1) { continue }
                    pos[Int(v0)] = p
                    q[Int(v0)] = q[Int(v0)] + q[Int(v1)]
                    let s = Int32(refs.count)
                    moveTriangles(of: v0, to: v0, dying0)
                    moveTriangles(of: v1, to: v0, dying1)
                    start[Int(v0)] = s; count[Int(v0)] = Int32(refs.count) - s
                    break
                }
            }
        }
    }
}
