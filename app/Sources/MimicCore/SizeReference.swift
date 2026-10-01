import Foundation
import simd

/// What the 3D view draws at true scale next to the mini (#98), since every mini is shown the
/// same height: a 28 mm goblin and a 100 mm dragon look alike without it. One choice for the
/// whole app, kept under `key`. The raw values are what's stored: never rename one.
public enum SizeReference: String, CaseIterable, Sendable {
    case none, base, person, grid

    public static let key = "sizeReference"
    /// A round base the size most minis stand on, and a person the height most minis are made at.
    public static let baseDiameter: Float = 25
    public static let personHeight: Float = 32

    /// In the view's menu.
    public var title: String {
        switch self {
        case .none: "None"
        case .base: "25 mm base"
        case .person: "32 mm person"
        case .grid: "Millimetre grid"
        }
    }

    /// For VoiceOver, after "3D view of Raven, 34 mm tall …": nil when nothing is drawn.
    public func spoken(gridSquare: Float) -> String? {
        switch self {
        case .none: nil
        case .base: "on a 25 mm base ring"
        case .person: "beside a 32 mm person"
        case .grid: "on a grid of \(Int(gridSquare)) mm squares"
        }
    }
}

/// Triangles for the 3D view to draw, in the scene's units, each one also wound the other way
/// so it's seen from both sides. `bold` picks the stronger colour (the grid's centimetre lines).
public struct ReferenceMesh: Equatable, Sendable {
    public var positions: [SIMD3<Float>] = []
    public var indices: [UInt32] = []
    public var bold = false

    /// A flat convex polygon, as a fan from its first corner.
    mutating func add(_ corners: [SIMD3<Float>]) {
        guard corners.count >= 3 else { return }
        let first = UInt32(positions.count)
        positions += corners
        for k in 1..<UInt32(corners.count - 1) {
            indices += [first, first + k, first + k + 1, first, first + k + 1, first + k]
        }
    }
}

/// Where the size reference goes and how big it is. The 3D view shows a mini scaled to 1 tall,
/// so a millimetre is 1 / its height; the reference turns, tilts and zooms with the mini.
public struct ReferenceLayout: Equatable, Sendable {
    public let kind: SizeReference
    /// The print file's height in millimetres, base included.
    public let height: Float
    /// The mini's box in the scene, 1 tall, centred on the origin: its floor is at -height/2.
    public let mini: SIMD3<Float>
    /// Where the middle of its base is on the floor (x, z): the print file's origin, which print
    /// prep puts under the feet. A print file from elsewhere may have it anywhere, so outside
    /// the footprint it's the middle of the box.
    public let centre: SIMD2<Float>

    /// How far above the floor the ring's band rises and the grid sits, so neither flickers
    /// against the base's underside, and how thick the drawn lines are. In the scene's units, so
    /// they look the same on a big mini as on a small one.
    static let lift: Float = 0.002
    static let ringBand: Float = 0.015
    static let line: Float = 0.004
    static let boldLine: Float = 0.008
    /// The smallest a grid square is drawn on screen, as a share of the mini's height.
    static let smallestSquare: Float = 0.025

    /// `origin` is where the print file's origin lands in the scene.
    public init(kind: SizeReference, height: Float, mini: SIMD3<Float>, origin: SIMD3<Float>) {
        self.kind = kind
        self.height = max(height, 1)
        self.mini = mini
        let inside = abs(origin.x) <= mini.x / 2 && abs(origin.z) <= mini.z / 2
        centre = inside ? SIMD2(origin.x, origin.z) : .zero
    }

    public var perMillimetre: Float { 1 / height }
    public var floor: Float { -mini.y / 2 }
    /// The inside of the ring, which a 25 mm base fills exactly: its band is drawn outside it.
    public var ringRadius: Float { SizeReference.baseDiameter * perMillimetre }
    public var personHeight: Float { SizeReference.personHeight * perMillimetre }
    /// A grid square's side in millimetres: 1 mm, or 2, 5 or 10 when a millimetre would be too
    /// small to see (a mini over 40 mm tall).
    public var gridSquare: Float {
        ([1, 2, 5, 10] as [Float]).first { $0 * perMillimetre >= Self.smallestSquare } ?? 10
    }
    public var gridSpacing: Float { gridSquare * perMillimetre }

    /// What to draw: nothing, or one or two meshes (the grid's thin and bold lines).
    public var meshes: [ReferenceMesh] {
        switch kind {
        case .none: []
        case .base: [ring]
        case .person: [person]
        case .grid: grid
        }
    }

    /// A band round the outside of a 25 mm circle, like the rim of a base: a little tube rather
    /// than a flat line, which nearly vanishes seen from the side.
    var ring: ReferenceMesh {
        var mesh = ReferenceMesh()
        let inner = ringRadius, outer = ringRadius + Self.ringBand
        let low = floor + Self.lift, high = floor + Self.lift + Self.ringBand
        let steps = 96
        func at(_ r: Float, _ y: Float, _ k: Int) -> SIMD3<Float> {
            let a = Float(k) / Float(steps) * 2 * .pi
            return SIMD3(centre.x + r * cos(a), y, centre.y + r * sin(a))
        }
        // The top, the outside and the inside of the band.
        let faces: [(Float, Float, Float, Float)] = [(inner, high, outer, high), (outer, low, outer, high), (inner, low, inner, high)]
        for k in 0..<steps {
            for (r1, y1, r2, y2) in faces {
                mesh.add([at(r1, y1, k), at(r2, y2, k), at(r2, y2, k + 1), at(r1, y1, k + 1)])
            }
        }
        return mesh
    }

    /// A plain standing figure, 32 mm tall, beside the mini (to its right as it faces you), clear
    /// of it however it's turned. Two cut-outs crossed at right angles, so it reads from the side too.
    var person: ReferenceMesh {
        var mesh = ReferenceMesh()
        let h = personHeight
        let middle = SIMD2(mini.x / 2 + 3 * perMillimetre + Self.personHalfWidth * h, 0)
        for part in Self.figure {
            for across in [SIMD2<Float>(1, 0), SIMD2(0, 1)] {
                mesh.add(part.map { p in
                    let side = middle + across * p.x * h
                    return SIMD3(side.x, floor + p.y * h, side.y)
                })
            }
        }
        return mesh
    }

    /// The figure's half width (hands to hands) as a share of its height.
    static let personHalfWidth: Float = 0.2

    /// The figure as convex pieces, x across from its middle and y up from its feet, both as a
    /// share of its height: head, body, arms, legs.
    static let figure: [[SIMD2<Float>]] = {
        let head = (0..<16).map { k -> SIMD2<Float> in
            let a = Float(k) / 16 * 2 * .pi
            return SIMD2(0.065 * cos(a), 0.93 + 0.07 * sin(a))
        }
        let body: [SIMD2<Float>] = [[-0.09, 0.5], [0.09, 0.5], [0.13, 0.84], [-0.13, 0.84]]
        let neck: [SIMD2<Float>] = [[-0.03, 0.82], [0.03, 0.82], [0.03, 0.87], [-0.03, 0.87]]
        let arm: [SIMD2<Float>] = [[0.11, 0.84], [0.135, 0.85], [0.2, 0.47], [0.155, 0.46]]
        let leg: [SIMD2<Float>] = [[0.005, 0.52], [0.09, 0.52], [0.085, 0], [0.025, 0]]
        let mirror = { (p: [SIMD2<Float>]) in p.reversed().map { SIMD2(-$0.x, $0.y) } }
        return [head, neck, body, arm, mirror(arm), leg, mirror(leg)]
    }()

    /// Square lines on the floor, centred on the base, a square's width apart and bolder every
    /// 10 mm, out a quarter beyond the mini's footprint (a whole number of squares, at least two).
    var grid: [ReferenceMesh] {
        var thin = ReferenceMesh(), bold = ReferenceMesh(bold: true)
        let reach = max(abs(centre.x) + mini.x / 2, abs(centre.y) + mini.z / 2) * 1.25
        let count = max(2, Int((reach / gridSpacing).rounded(.up)))
        let half = Float(count) * gridSpacing, y = floor + Self.lift
        let every = max(1, Int((10 / gridSquare).rounded()))
        for k in -count...count {
            let isBold = k % every == 0
            let w = (isBold ? Self.boldLine : Self.line) / 2, at = Float(k) * gridSpacing
            let across: [SIMD3<Float>] = [[-half, y, at - w], [half, y, at - w], [half, y, at + w], [-half, y, at + w]]
            let along: [SIMD3<Float>] = [[at - w, y, -half], [at + w, y, -half], [at + w, y, half], [at - w, y, half]]
            for line in [across, along] {
                let moved = line.map { $0 + SIMD3(centre.x, 0, centre.y) }
                if isBold { bold.add(moved) } else { thin.add(moved) }
            }
        }
        return [thin, bold].filter { !$0.indices.isEmpty }
    }

    /// The box the 3D view's camera fits, centred on the origin like the mini's: the mini and the
    /// reference, however it's turned round (so as wide as it is deep), and as far below the
    /// middle as above, so the mini stays in the middle of the view.
    public var fit: SIMD3<Float> {
        var across = max(mini.x, mini.z) / 2, up = mini.y / 2
        for mesh in meshes {
            for p in mesh.positions {
                across = max(across, simd_length(SIMD2(p.x, p.z)))
                up = max(up, abs(p.y))
            }
        }
        return kind == .none ? mini : SIMD3(2 * across, 2 * up, 2 * across)
    }
}
