import simd

extension Mesh {
    /// Sets an object that can't stand as it is on a steadier side near its bottom, and returns by
    /// how many degrees it turned it (0: left as it is, positions untouched; nil: no side near its
    /// bottom holds it up, positions untouched). Run after `level()`.
    ///
    /// The sides it could rest on are the faces of its convex hull, a side being the hull faces
    /// lying flat together (within 3°), not every point near the floor: on a round body that is a
    /// disc that looks like a small flat, and made every real model "stand" at every angle. On a
    /// side, its centre of mass (`centreOfMass`) sits r in from the nearest edge of what it rests
    /// on and h above it; tilted by more than atan(r/h) it tips over, and sqrt(r² + h²) - h is the
    /// lift that takes. A side it stands on is one it survives a `minTip` tilt on. Measured on
    /// real models: their bases 13–26° (teapot2, vase, teapot, and figures on their feet down to
    /// the elf's 8.4°); lying on their sides or upside down, nothing within 30° of down above
    /// 6.1°. A box 4 or 6 times as tall as wide stands (14°, 9.5°); 8 times (7.1°) can't stand.
    /// One exception it gets wrong on purpose: the vase upside down stands on its mouth's rim
    /// (9.2°), and stays there, because it can.
    ///
    /// Standing on a side within `standing` of straight down, it is left as it is, however much
    /// steadier lying down would be: a vase, a tall box or a statue that stands is never laid
    /// down. Otherwise it goes onto the steadiest side within `limit` (it was levelled onto the
    /// edge of its foot: the real teapot sat 20° off its foot, levelled by only 2.8°). Never
    /// further: the engine keeps the picture's up, and the real models laid on their sides or
    /// backs were upright figures that can't stand without a base (a hoodie guy on small feet, a
    /// raven on a perch), not objects that came out lying down.
    mutating func rest(limit: Float = 30, standing: Double = 10, minTip: Double = 8,
                       moved: (simd_quatf, SIMD3<Float>) -> Void = { _, _ in }) -> Float? {
        let keep = mainTriangles()  // floating specks sit on the hull too, and aren't what it rests on
        var used = [Bool](repeating: false, count: positions.count)
        for (t, k) in zip(triangles, keep) where k { used[Int(t.x)] = true; used[Int(t.y)] = true; used[Int(t.z)] = true }
        var lo = SIMD3<Float>(repeating: .infinity), hi = -lo
        for (p, u) in zip(positions, used) where u { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let size = Double((hi - lo).max())
        guard size > 0 else { return 0 }

        // One point per cell of a 256-cell grid is plenty to find the sides by, and keeps the
        // hull of a million vertices small.
        let cell = Float(size / 256)
        var seen = Set<SIMD3<Int32>>(), points: [SIMD3<Double>] = []
        for (p, u) in zip(positions, used) where u && seen.insert(SIMD3<Int32>(((p - lo) / cell).rounded(.down))).inserted {
            points.append(SIMD3<Double>(p))
        }
        guard let hull = Hull(points) else { return 0 }
        let com = centreOfMass(keep)

        // Each hull face is a side; facets of one flat side (or nearly) are one candidate. 3°
        // apart is plenty: levelling squares up whatever side ends up down.
        var sides: [SIMD3<Int32>: (n: SIMD3<Double>, area: Double)] = [:]
        for f in hull.faces {
            let key = SIMD3<Int32>((f.n * 19).rounded(.toNearestOrAwayFromZero))
            if f.area > sides[key]?.area ?? -1 { sides[key] = (f.n, f.area) }
        }
        let band = 0.01 * size  // what --flatten slices off an object 32 mm long (0.4 mm), about
        let cone = cos(3 * Double.pi / 180)
        func tipping(_ down: SIMD3<Double>) -> (angle: Double, lift: Double, normal: SIMD3<Double>) {
            // What it rests on: the hull faces lying flat along this side, not every point within
            // the band, which on a round body is a disc that looks like a small flat.
            var support = -Double.infinity
            for i in hull.vertices { support = max(support, simd_dot(points[i], down)) }
            let u = simd_normalize(simd_cross(down, abs(down.x) < 0.9 ? [1, 0, 0] : [0, 1, 0])), w = simd_cross(down, u)
            var patch: [SIMD2<Double>] = [], normal = SIMD3<Double>()
            for f in hull.faces where simd_dot(f.n, down) > cone && f.d > support - band {
                normal += f.area * f.n  // the side's own facing: exact for a flat one, the mean of an uneven one
                for i in [f.v.x, f.v.y, f.v.z] { patch.append(SIMD2(simd_dot(points[i], u), simd_dot(points[i], w))) }
            }
            let r = Self.inset(SIMD2(simd_dot(com, u), simd_dot(com, w)), in: Self.hull2D(patch))
            let h = support - simd_dot(com, down)
            return r > 0 ? (atan2(r, h) * 180 / .pi, (r * r + h * h).squareRoot() - h, simd_normalize(normal)) : (0, 0, down)
        }
        var near: (down: SIMD3<Double>, lift: Double)?
        // Nearest to down first, and a side has to be 1% steadier to win, so of two as steady (a
        // box's opposite faces) it takes the smaller turn, the same one every run: a dictionary's
        // order changes from run to run.
        for side in sides.values.sorted(by: { $0.n.z < $1.n.z }) {
            let t = tipping(side.n)
            guard t.angle >= minTip else { continue }
            let off = acos(min(1, -t.normal.z)) * 180 / .pi
            if off <= standing { return 0 }  // it stands as it is
            if off <= Double(limit) && t.lift > 1.01 * (near?.lift ?? 0) { near = (t.normal, t.lift) }
        }
        guard let down = near?.down else { return nil }

        let from = SIMD3<Float>(simd_normalize(down))
        let turn = from.z > 0.9999 ? simd_quatf(angle: .pi, axis: [1, 0, 0]) : simd_quatf(from: from, to: [0, 0, -1])
        let centre = (lo + hi) / 2
        for n in positions.indices { positions[n] = turn.act(positions[n] - centre) + centre }
        moved(turn, centre)
        return acos(max(-1, min(1, -from.z))) * 180 / .pi
    }

    /// The solid's centre of mass, from the triangles marked in `keep`: the volume centroid when
    /// they close up (measured from two different points, a closed surface encloses the same
    /// volume), else the surface's area centroid. The generator's winding isn't reliable, and a
    /// surface that doesn't close has no inside to weigh, but its skin is where the solid is.
    func centreOfMass(_ keep: [Bool]) -> SIMD3<Double> {
        let (lo, hi) = bounds
        let origins = [SIMD3<Double>((lo + hi) / 2), SIMD3<Double>(lo) - SIMD3<Double>(hi - lo)]
        var volume = [0.0, 0.0], moment = SIMD3<Double>(), area = 0.0, skin = SIMD3<Double>()
        for (t, k) in zip(triangles, keep) where k {
            let a = SIMD3<Double>(positions[Int(t.x)]), b = SIMD3<Double>(positions[Int(t.y)]), c = SIMD3<Double>(positions[Int(t.z)])
            for (i, o) in origins.enumerated() {
                let v = simd_dot(a - o, simd_cross(b - o, c - o)) / 6
                volume[i] += v
                if i == 0 { moment += v * (a + b + c + o) / 4 }
            }
            let da = simd_length(simd_cross(b - a, c - a)) / 2
            area += da; skin += da * (a + b + c) / 3
        }
        if volume[0] != 0 && abs(volume[0] - volume[1]) < 0.01 * abs(volume[0]) { return moment / volume[0] }
        return area > 0 ? skin / area : origins[0]
    }

    /// Convex hull of points in the plane, counter-clockwise (Andrew's monotone chain).
    static func hull2D(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var h: [SIMD2<Double>] = []
        for pass in [p, p.reversed()] {
            let start = h.count
            for q in pass {
                while h.count >= start + 2 && cross(h[h.count - 2], h[h.count - 1], q) <= 0 { h.removeLast() }
                h.append(q)
            }
            h.removeLast()
        }
        return h
    }

    /// How far `p` is inside a counter-clockwise convex polygon from its nearest edge (≤ 0 outside
    /// or when the polygon has no area).
    static func inset(_ p: SIMD2<Double>, in polygon: [SIMD2<Double>]) -> Double {
        guard polygon.count > 2 else { return 0 }
        var r = Double.infinity
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count], e = b - a
            r = min(r, (e.x * (p.y - a.y) - e.y * (p.x - a.x)) / simd_length(e))
        }
        return r
    }
}

/// 3D convex hull (quickhull): each point is assigned to a face it's outside of; the farthest
/// one of a face becomes a vertex, the faces it sees are replaced by a fan from it to their rim.
struct Hull {
    struct Face { var v: SIMD3<Int>; var n: SIMD3<Double>; var d: Double; var area: Double; var outside: [Int] = []; var alive = true }
    private(set) var faces: [Face] = []
    private(set) var vertices: [Int] = []

    init?(_ p: [SIMD3<Double>]) {
        guard p.count >= 4 else { return nil }
        var lo = p[0], hi = p[0]
        for q in p { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let eps = 1e-7 * (hi - lo).max()
        func plane(_ a: Int, _ b: Int, _ c: Int) -> Face {
            let x = simd_cross(p[b] - p[a], p[c] - p[a]), l = simd_length(x)
            let n = l > 0 ? x / l : .zero
            return Face(v: [a, b, c], n: n, d: simd_dot(n, p[a]), area: l / 2)
        }
        // A first tetrahedron from extreme points, or nothing if the points are flat.
        let i0 = p.indices.min { p[$0].x < p[$1].x }!, i1 = p.indices.max { p[$0].x < p[$1].x }!
        let axis = simd_normalize(p[i1] - p[i0])
        func offLine(_ i: Int) -> Double { simd_length(simd_cross(p[i] - p[i0], axis)) }
        let i2 = p.indices.max { offLine($0) < offLine($1) }!
        guard simd_length(p[i1] - p[i0]) > eps, offLine(i2) > eps else { return nil }
        let base = plane(i0, i1, i2)
        let i3 = p.indices.max { abs(simd_dot(base.n, p[$0]) - base.d) < abs(simd_dot(base.n, p[$1]) - base.d) }!
        guard abs(simd_dot(base.n, p[i3]) - base.d) > eps else { return nil }
        let inner = (p[i0] + p[i1] + p[i2] + p[i3]) / 4
        for (a, b, c) in [(i0, i1, i2), (i0, i2, i3), (i0, i3, i1), (i1, i3, i2)] {
            var f = plane(a, b, c)
            if simd_dot(f.n, inner) - f.d > 0 { f = plane(a, c, b) }
            faces.append(f)
        }
        var edges: [SIMD2<Int>: Int] = [:]  // directed edge -> the face it runs round
        func link(_ f: Int) { let v = faces[f].v; edges[[v.x, v.y]] = f; edges[[v.y, v.z]] = f; edges[[v.z, v.x]] = f }
        func distance(_ f: Int, _ i: Int) -> Double { simd_dot(faces[f].n, p[i]) - faces[f].d }
        func assign(_ points: [Int], to candidates: [Int]) {
            for i in points {
                if let f = candidates.first(where: { distance($0, i) > eps }) { faces[f].outside.append(i) }
            }
        }
        for f in faces.indices { link(f) }
        assign(Array(p.indices).filter { ![i0, i1, i2, i3].contains($0) }, to: Array(faces.indices))

        var pending = Array(faces.indices)
        while let f = pending.popLast() {
            guard faces[f].alive, !faces[f].outside.isEmpty else { continue }
            let eye = faces[f].outside.max { distance(f, $0) < distance(f, $1) }!
            // The faces the eye sees, and the rim around them.
            var visible = [f], seen: Set<Int> = [f], rim: [SIMD2<Int>] = [], k = 0
            while k < visible.count {
                let v = faces[visible[k]].v
                for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] {
                    guard let g = edges[[b, a]] else { continue }
                    if seen.contains(g) { continue }
                    if distance(g, eye) > eps { seen.insert(g); visible.append(g) } else { rim.append([a, b]) }
                }
                k += 1
            }
            var orphans: [Int] = []
            for g in visible {
                faces[g].alive = false
                orphans += faces[g].outside
                faces[g].outside = []
                let v = faces[g].v
                for e in [SIMD2(v.x, v.y), SIMD2(v.y, v.z), SIMD2(v.z, v.x)] where edges[e] == g { edges[e] = nil }
            }
            var made: [Int] = []
            for e in rim {
                faces.append(plane(e.x, e.y, eye))
                link(faces.count - 1); made.append(faces.count - 1)
            }
            assign(orphans.filter { $0 != eye }, to: made)
            pending += made
        }
        faces.removeAll { !$0.alive }
        vertices = Array(Set(faces.flatMap { [$0.v.x, $0.v.y, $0.v.z] }))
    }
}
