import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers
import XCTest
@testable import MimicCore

/// Colour from the 3D engine (#256): print prep records where it put the engine's model, and a
/// point on the print file takes the colour of that model under it.
final class EngineColoursTests: XCTestCase {
    func temporary() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("colours-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// Each face's colour, in `paintedBox`'s order: -x, +x, -y, +y, -z, +z.
    static let red: SIMD3<UInt8> = [255, 0, 0], green: SIMD3<UInt8> = [0, 255, 0], blue: SIMD3<UInt8> = [0, 0, 255]
    static let yellow: SIMD3<UInt8> = [255, 255, 0], magenta: SIMD3<UInt8> = [255, 0, 255], cyan: SIMD3<UInt8> = [0, 255, 255]
    static let faces = [red, green, blue, yellow, magenta, cyan]

    /// A box with a colour on each face, as the engine writes a painted model: corners of their
    /// own on each face (a face's place on the picture is its own), and a 6 × 1 picture.
    static func paintedBox(half h: SIMD3<Float>) -> Data {
        var m = Mesh(), uv: [SIMD2<Float>] = []
        for (f, (axis, sign)) in [(0, -1), (0, 1), (1, -1), (1, 1), (2, -1), (2, 1)].enumerated() {
            let u = (axis + 1) % 3, v = (axis + 2) % 3, base = UInt32(m.positions.count)
            for (a, b) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] {
                var p = SIMD3<Float>.zero
                p[axis] = Float(sign) * h[axis]; p[u] = Float(a) * h[u]; p[v] = Float(b) * h[v]
                m.positions.append(p); uv.append([(Float(f) + 0.5) / 6, 0.5])
            }
            // u × v points along the axis, so these face out.
            m.triangles += sign > 0 ? [[base, base + 1, base + 2], [base, base + 2, base + 3]]
                                    : [[base, base + 2, base + 1], [base, base + 3, base + 2]]
        }
        let pixels: [UInt8] = faces.flatMap { [$0.x, $0.y, $0.z, 255] as [UInt8] }
        let png = NSMutableData()
        let image = CGImage(width: 6, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 24,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return GLB.encode(m, paint: (uv, png as Data))
    }

    static func bounds(_ points: [SIMD3<Float>]) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) { Mesh(positions: points).bounds }

    static func moved(_ p: SIMD3<Float>, _ m: simd_double4x4) -> SIMD3<Float> {
        let q = m * SIMD4(SIMD3<Double>(p), 1)
        return SIMD3(Float(q.x), Float(q.y), Float(q.z))
    }

    /// Where the record puts the model is where the print file is: an object leaning 12° and
    /// turned round (levelled, sized, centred, sunk into the base, its bottom flattened) lies
    /// just under the print file's surface, and each point of the print file, undone, lies just
    /// off the model as the engine made it.
    func testPrintPrepRecordsWhereItPutTheModel() throws {
        let d = try temporary()
        var model = PrepTests.box(half: [4, 3, 10])
        let lean = simd_quatf(angle: 12 * .pi / 180, axis: [1, 0, 0])
        model.positions = model.positions.map { lean.act($0) + [5, -2, 7] }
        let glb = d.appendingPathComponent("model.glb"), stl = d.appendingPathComponent("m.stl")
        try GLB.encode(model).write(to: glb)
        let o = try PrepOptions.parse([glb.path, stl.path, "--fit", "longest", "--ground", "bottom", "--turn", "180", "--voxel", "0.4"])
        let result = try Prep.run(o)
        let toPrint = try XCTUnwrap(Placement.read(d), "kept beside the print file")
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(toPrint[c][r], result.toPrint[c][r], accuracy: 1e-12) } }

        let inflate = Float(o.effectiveInflate)
        let printed = try PrepTests.Printed(stl).positions.filter { $0.z > Float(o.effectiveBaseHeight) + 1 }  // above the base
        let p = Self.bounds(printed), m = Self.bounds(model.positions.map { Self.moved($0, toPrint) })
        XCTAssertEqual(p.hi.z, m.hi.z + inflate, accuracy: 0.1, "the top, flattened bottom and all")
        XCTAssertEqual(p.hi.z - Float(o.effectiveBaseHeight - o.flatten), 32 - 0.6 + inflate, accuracy: 0.1, "sized and sunk")
        for a in 0..<2 {
            XCTAssertEqual(p.lo[a], m.lo[a] - inflate, accuracy: 0.1)
            XCTAssertEqual(p.hi[a], m.hi[a] + inflate, accuracy: 0.1)
        }

        let back = toPrint.inverse, grows = Float(cbrt(abs(simd_determinant(toPrint))))
        XCTAssertEqual(grows, 32 / 20, accuracy: 1e-4, "its longest side, 20, made 32 mm")
        for q in stride(from: 0, to: printed.count, by: max(1, printed.count / 200)).map({ printed[$0] }) {
            let onModel = Self.moved(q, back)
            let off = model.triangles.map {
                EngineColours.closest(onModel, model.positions[Int($0.x)], model.positions[Int($0.y)], model.positions[Int($0.z)]).d2
            }.min()!.squareRoot()
            XCTAssertEqual(off * grows, inflate, accuracy: 0.1, "\(q) undone is \(onModel)")
        }
    }

    /// A record only sits beside the print file it was written with: a run that fails (or is
    /// stopped) takes away the one an earlier run left, which no longer says where its model is.
    func testAFailedPrintPrepLeavesNoRecordBehind() throws {
        let d = try temporary()
        let glb = d.appendingPathComponent("model.glb"), stl = d.appendingPathComponent("m.stl")
        try Placement(matrix_identity_double4x4).write(beside: stl)
        XCTAssertNotNil(Placement.read(d))
        try GLB.encode(PrepTests.box(half: [10, 10, 0.01])).write(to: glb)  // a flat sheet: prep refuses it
        XCTAssertThrowsError(try Prep.run(PrepOptions.parse([glb.path, stl.path, "--voxel", "0.4"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent(Placement.file).path), "a stale record was left")
    }

    /// A point on the print file has the colour of the face it covers, for a model prep left
    /// facing as made (TRELLIS.2's) and one it turned round (Pixal3D's, `EngineModel.turn`): the
    /// face the engine painted on the model's back is then the print file's front. The base has none.
    func testTheColourIsThatOfTheNearestPointOnTheEnginesModel() throws {
        for turn in [0, 180] {
            let d = try temporary()
            let glb = d.appendingPathComponent("model.glb"), stl = d.appendingPathComponent("m.stl")
            try Self.paintedBox(half: [4, 3, 10]).write(to: glb)
            _ = try Prep.run(PrepOptions.parse([glb.path, stl.path, "--voxel", "0.4", "--turn", String(turn)]))
            let read = try GLB.read(painted: glb)
            let colours = try EngineColours(model: read.mesh, paint: XCTUnwrap(read.paint), toPrint: XCTUnwrap(Placement.read(d)))

            let b = Self.bounds(try PrepTests.Printed(stl).positions.filter { $0.z > 4 }), mid = (b.lo + b.hi) / 2
            let turned = turn == 180
            XCTAssertEqual(colours.colour(at: [mid.x, b.lo.y, mid.z]), turned ? Self.yellow : Self.blue, "the front, turned \(turn)")
            XCTAssertEqual(colours.colour(at: [mid.x, b.hi.y, mid.z]), turned ? Self.blue : Self.yellow, "the back, turned \(turn)")
            XCTAssertEqual(colours.colour(at: [b.lo.x, mid.y, mid.z]), turned ? Self.green : Self.red, "-x, turned \(turn)")
            XCTAssertEqual(colours.colour(at: [b.hi.x, mid.y, mid.z]), turned ? Self.red : Self.green, "+x, turned \(turn)")
            XCTAssertEqual(colours.colour(at: [mid.x, mid.y, b.hi.z]), Self.cyan, "the top, turned \(turn)")
            XCTAssertNil(colours.colour(at: [11, 0, 2]), "the base's edge is nowhere near the model")
        }
    }

    /// A block of skin with a hair strand 0.4 mm wide lying 0.2 mm proud across its top, painted
    /// as the engine paints, `scale` times that size.
    static func strand(scale s: Float = 1) throws -> (mesh: Mesh, paint: GLB.Paint) {
        var m = Mesh(), uv: [SIMD2<Float>] = []
        func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, _ u: Float) {
            let base = UInt32(m.positions.count)
            for i in 0..<8 {
                m.positions.append(s * SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z))
                uv.append([u, 0.5])
            }
            for f: SIMD3<UInt32> in [[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5], [0, 4, 5], [0, 5, 1],
                                     [2, 3, 7], [2, 7, 6], [0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3]] { m.triangles.append(f &+ base) }
        }
        box([-10, -10, -5], [10, 10, 5], 0.25)  // skin: the picture's left pixel
        box([-0.2, -8, 5], [0.2, 8, 5.2], 0.75)  // the strand: its right
        let pixels: [UInt8] = [skin, dark].flatMap { [$0.x, $0.y, $0.z, 255] as [UInt8] }
        let png = NSMutableData()
        let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        let read = try GLB.parse(GLB.encode(m, paint: (uv, png as Data)), painted: true)
        return (read.mesh, try XCTUnwrap(read.paint))
    }
    static let skin: SIMD3<UInt8> = [230, 200, 180], dark: SIMD3<UInt8> = [30, 25, 20]

    /// Print prep pushes the surface out (--inflate), so the print file lies a little off the
    /// engine's model everywhere. Beside a raised strand, the nearest point on the model is the
    /// strand's edge, not the skin under the surface: nearest point widened every strand, cord
    /// and eyebrow by the push on each side, and smeared Lorelei's face. Along the surface's
    /// normal, the strand keeps its width.
    func testAThinStrandStaysThinUnderThePushedOutSurface() throws {
        let model = try Self.strand()
        let colours = try EngineColours(model: model.mesh, paint: model.paint, toPrint: matrix_identity_double4x4)
        let up: SIMD3<Float> = [0, 0, 1]
        // The print file's top, 0.25 mm over the skin and 0.05 mm over the strand.
        let over: SIMD3<Float> = [0, 0, 5.25], beside: SIMD3<Float> = [0.35, 0, 5.25]
        XCTAssertEqual(colours.colour(at: beside), Self.dark, "the nearest point is the strand's edge")
        XCTAssertEqual(colours.colour(at: over, along: up), Self.dark, "over the strand")
        XCTAssertEqual(colours.colour(at: beside, along: up), Self.skin, "beside it, the skin under the surface")
        XCTAssertEqual(colours.colour(at: beside, along: -up), Self.skin, "whichever way the normal points")
        XCTAssertEqual(colours.colour(at: [10.1, 0, 0], along: up), Self.skin, "the line misses: the nearest point's colour")
        XCTAssertNil(colours.colour(at: [30, 0, 0], along: up), "nothing near: the base")
    }

    /// The walk along a line visits every grid cell the line passes through, so it misses no
    /// triangle there: checked against points every 1/2000 of the way, on lines every way.
    func testTheWalkAlongALineMissesNoCell() {
        var seed: UInt64 = 42, m = Mesh()
        func r() -> Float {  // the same every run
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        for _ in 0..<1000 {  // small triangles all over a cube: a grid about 50 cells a side
            let p = SIMD3(r(), r(), r()), base = UInt32(m.positions.count)
            m.positions += [p, p + [0.01, 0, 0], p + [0, 0.01, 0]]
            m.triangles.append([base, base + 1, base + 2])
        }
        let grid = EngineColours.Nearest(m)
        XCTAssertGreaterThan(grid.dims.min(), 20)
        for _ in 0..<200 {
            let a = SIMD3(r(), r(), r()) * 1.2 - 0.1, b = SIMD3(r(), r(), r()) * 1.2 - 0.1  // ends may lie off the grid
            var walked: [Int] = []
            grid.cells(from: a, to: b) { walked.append($0) }
            XCTAssertEqual(Set(walked).count, walked.count, "a cell twice")
            for k in 0...2000 {
                let p = a + (b - a) * Float(k) / 2000, at = SIMD3<Int32>(((p - grid.lo) / grid.cell).rounded(.down))
                guard all(at .>= .zero) && all(at .< grid.dims) else { continue }
                XCTAssertTrue(walked.contains(grid.index(at)), "\(a) to \(b) skipped the cell at \(p)")
            }
        }
    }

    /// The line reaches 3% of the model's height each way, and no more than 2 mm: on a big mini a
    /// neighbouring part a few millimetres off isn't what's under the surface.
    func testTheLineReachesNoMoreThanTwoMillimetres() throws {
        for (scale, reach) in [(1, 0.03 * 10.2), (20, 2)] as [(Float, Float)] {
            let model = try Self.strand(scale: scale)
            let colours = try EngineColours(model: model.mesh, paint: model.paint, toPrint: matrix_identity_double4x4)
            XCTAssertEqual(colours.reach, reach, accuracy: 1e-4, "\(scale) times the size")
            let colours2 = try EngineColours(model: model.mesh, paint: model.paint, toPrint: simd_double4x4(diagonal: [2, 2, 2, 1]))
            XCTAssertEqual(colours2.reach * 2, min(2 * reach, 2), accuracy: 1e-4, "in millimetres as placed, \(scale) times the size, doubled")
        }
    }

    /// Export for Virtual Tabletop paints with the engine's colours only when the engine saw
    /// them: a Pixal3D mini made from a colour picture without the grey sculpt comes out with
    /// its back's colour on its front (turned round as prep turned it), with or without the
    /// record (a mini prepped before it is placed again); the grey sculpt, a fix to the picture
    /// or a description come out grey.
    func testTheTabletopExportIsInTheEnginesColoursOnlyWhenTheEngineSawThem() throws {
        let folder = try temporary().appendingPathComponent("lorelei")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let glb = folder.appendingPathComponent(Mini.modelFile), stl = folder.appendingPathComponent("lorelei.stl")
        try Self.paintedBox(half: [4, 3, 10]).write(to: glb)
        var settings = MiniSettings()
        settings.source = .image; settings.model = "pixal3d-sv"; settings.restyle = false; settings.facesFront = true
        _ = try Prep.run(PrepOptions.parse([glb.path, stl.path] + Pipeline.prepFlags(settings) + ["--voxel", "0.4"]))

        func front(_ change: (inout MiniSettings) -> Void = { _ in }) throws -> SIMD3<UInt8>? {
            var s = settings
            change(&s)
            let out = folder.appendingPathComponent("tabletop.glb")
            let made = try Tabletop.export(Mini(name: "lorelei", folder: folder, madeAt: Date(), settings: s), to: out, triangles: 200)
            let read = try GLB.read(painted: out)
            XCTAssertEqual(made.colour, read.paint != nil, "says whether it's in colour")
            guard let paint = read.paint else { return nil }
            let image = try XCTUnwrap(CGImageSourceCreateWithData(paint.image as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let pixels = try Engine.rgba(image, opaque: true)
            // Every triangle facing glTF's front (-y read back), halfway up: its cell's middle.
            var seen: [SIMD3<UInt8>] = []
            for t in read.mesh.triangles {
                let c = [t.x, t.y, t.z].map { read.mesh.positions[Int($0)] }
                let n = simd_normalize(simd_cross(c[1] - c[0], c[2] - c[0])), z = (c[0].z + c[1].z + c[2].z) / 3
                guard n.y < -0.9, z > 0.01, z < 0.03 else { continue }
                let at = [t.x, t.y, t.z].map { paint.uv[Int($0)] }.reduce(.zero, +) / 3
                let o = 4 * (Int(at.y * Float(image.height)) * image.width + Int(at.x * Float(image.width)))
                seen.append(SIMD3(pixels[o], pixels[o + 1], pixels[o + 2]))
            }
            XCTAssertFalse(seen.isEmpty)
            // JPEG: near the colour, not exactly it.
            let first = seen[0]
            XCTAssertTrue(seen.allSatisfy { simd_reduce_max(simd_abs(SIMD3<Int16>(truncatingIfNeeded: $0) &- SIMD3<Int16>(truncatingIfNeeded: first))) < 40 }, "\(seen)")
            return first
        }
        func near(_ a: SIMD3<UInt8>?, _ b: SIMD3<UInt8>) -> Bool {
            guard let a else { return false }
            return simd_reduce_max(simd_abs(SIMD3<Int16>(truncatingIfNeeded: a) &- SIMD3<Int16>(truncatingIfNeeded: b))) < 40
        }

        let coloured = try front()
        XCTAssertTrue(near(coloured, Self.yellow), "the model's +y is the print file's front: \(String(describing: coloured))")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(Placement.file))
        XCTAssertTrue(near(try front(), Self.yellow), "placed again without the record")
        let stopped = try front { $0.made = Sizes(); $0.requested = Sizes(height: "60") }
        XCTAssertTrue(near(stopped, Self.yellow), "placed at the sizes the print file was made at, not a resize's that didn't finish: \(String(describing: stopped))")
        XCTAssertNil(try front { $0.restyle = true }, "the grey sculpt")
        XCTAssertNil(try front { $0.fixes = ["give her a hat"] }, "a fix is always redrawn as a sculpt")
        XCTAssertNil(try front { $0.source = .desc }, "drawn from a description")

        // Grey when it should have been in colour says why, instead of passing for in colour (#317).
        func whyGrey(_ change: (inout MiniSettings) -> Void = { _ in }) throws -> String? {
            var s = settings
            change(&s)
            let made = try Tabletop.export(Mini(name: "lorelei", folder: folder, madeAt: Date(), settings: s),
                                           to: folder.appendingPathComponent("tabletop.glb"), triangles: 200)
            XCTAssertEqual(made.colour, made.whyGrey == nil && Tabletop.inColour(s), "grey with a reason, or not expected in colour")
            return made.whyGrey
        }
        XCTAssertNil(try whyGrey(), "in colour")
        XCTAssertNil(try whyGrey { $0.restyle = true }, "grey, as the save window said")
        XCTAssertEqual(try whyGrey { $0.model = "no-such-engine" }, "this Mimic doesn't know the 3D model it was made with, no-such-engine",
                       "placed again (no record) by a model this Mimic doesn't have")
        try GLB.encode(PrepTests.box(half: [4, 3, 10])).write(to: glb)
        XCTAssertEqual(try whyGrey(), "its 3D model has no colours saved with it")
        try Data("not a model".utf8).write(to: glb)
        XCTAssertEqual(try whyGrey(), "Mimic couldn't read the colours from its 3D model")
        try FileManager.default.removeItem(at: glb)
        XCTAssertEqual(try whyGrey(), "its 3D model is missing from its folder")
    }
}
