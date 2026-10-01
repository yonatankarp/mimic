import Foundation
import ImageIO
import simd
import XCTest
@testable import MimicCore

/// Ported from tests/test_prep.sh and tests/check_prep.py: print prep on a synthetic figure
/// that carries every defect prep exists to fix, each one seen in a real run: a floating speck,
/// a paper-thin blade, a figure off the origin, and a wisp trailing below the feet (the
/// tiefling's robe, which once stood the whole figure on a pin).
///
/// One change: check_prep.py's blade floated 0.5 mm clear of the body, so Blender dropped it
/// with the speck as a loose piece and nothing checked it. Here it is held out from the body,
/// 0.1 mm thick at print size (thinner than a voxel), and has to survive.
final class PrepTests: XCTestCase {
    // MARK: The fixture, in Blender's units and axes (z up), as check_prep.py built it

    static func fixture() -> Mesh {
        var m = Mesh()
        m.add(cylinder(radius: 0.35, depth: 2), at: [0, 0, 1])                        // body, feet at z=0
        m.add(sphere(radius: 0.35), at: [0, 0, 2.3])                                   // head
        m.add(box(half: [0.25, 0.004, 0.08]), at: [0.55, 0, 1.4])                      // paper-thin blade, held out
        m.add(sphere(radius: 0.04), at: [1.5, 0, 1.5])                                 // floating speck
        m.add(cylinder(radius: 0.03, depth: 0.5, tilt: 0.6), at: [0, 0.45, 0.05])     // wisp below the feet
        return m
    }

    static func cylinder(radius: Float, depth: Float, tilt: Float = 0, segments: Int = 32) -> Mesh {
        var m = Mesh()
        for z in [-depth / 2, depth / 2] {
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                m.positions.append([radius * cos(a), radius * sin(a), z])
            }
        }
        let n = UInt32(segments)
        m.positions += [[0, 0, -depth / 2], [0, 0, depth / 2]]
        for s in 0..<n {
            let t = (s + 1) % n
            m.triangles += [[s, t, n + t], [s, n + t, n + s], [2 * n, t, s], [2 * n + 1, n + s, n + t]]
        }
        let turn = simd_float3x3(simd_quatf(angle: tilt, axis: [1, 0, 0]))
        m.positions = m.positions.map { turn * $0 }
        return m
    }

    static func sphere(radius: Float, rings: Int = 16, segments: Int = 32) -> Mesh {
        var m = Mesh(positions: [[0, 0, -radius], [0, 0, radius]])
        for r in 1..<rings {
            let polar = Float(r) / Float(rings) * .pi
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                m.positions.append([radius * sin(polar) * cos(a), radius * sin(polar) * sin(a), -radius * cos(polar)])
            }
        }
        let seg = UInt32(segments), ring = { (r: Int, s: UInt32) in UInt32(2 + (r - 1) * segments) + s % seg }
        for s in 0..<seg {
            m.triangles.append([0, ring(1, s + 1), ring(1, s)])
            m.triangles.append([1, ring(rings - 1, s), ring(rings - 1, s + 1)])
            for r in 1..<(rings - 1) {
                m.triangles += [[ring(r, s), ring(r, s + 1), ring(r + 1, s + 1)], [ring(r, s), ring(r + 1, s + 1), ring(r + 1, s)]]
            }
        }
        return m
    }

    static func box(half: SIMD3<Float>) -> Mesh {
        var m = Mesh()
        for c in 0..<8 { m.positions.append(half * SIMD3(c & 1 == 0 ? -1 : 1, c & 2 == 0 ? -1 : 1, c & 4 == 0 ? -1 : 1)) }
        m.triangles = [[0, 2, 3], [0, 3, 1], [4, 5, 7], [4, 7, 6], [0, 1, 5], [0, 5, 4],
                       [2, 6, 7], [2, 7, 3], [0, 4, 6], [0, 6, 2], [1, 3, 7], [1, 7, 5]]
        return m
    }

    /// A .glb of `mesh` the way the 3D engine writes one: y up, and here placed by its node
    /// (nowhere near the origin), so the reader's axes and transforms are both on trial. `edit`
    /// changes the scene description, to try the reader on a damaged file.
    static func glb(_ mesh: Mesh, translation: SIMD3<Float>, edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var bin = Data()
        for p in mesh.positions { for v in [p.x, p.z, -p.y] { withUnsafeBytes(of: v) { bin.append(contentsOf: $0) } } }
        let indexStart = bin.count
        for t in mesh.triangles { for v in [t.x, t.y, t.z] { withUnsafeBytes(of: v) { bin.append(contentsOf: $0) } } }
        var json: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "translation": [translation.x, translation.z, -translation.y]]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": mesh.positions.count, "type": "VEC3"],
                          ["bufferView": 1, "componentType": 5125, "count": mesh.triangles.count * 3, "type": "SCALAR"]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": indexStart],
                            ["buffer": 0, "byteOffset": indexStart, "byteLength": bin.count - indexStart]],
            "buffers": [["byteLength": bin.count]],
        ]
        edit(&json)
        var text = try! JSONSerialization.data(withJSONObject: json)
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); out.append(text)
        u32(bin.count); u32(0x004E_4942); out.append(bin)
        return out
    }

    // MARK: Checks on the written print file

    /// The STL's triangles, welded by exact position like a slicer does.
    struct Printed {
        var positions: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int>] = []

        init(_ url: URL) throws {
            var index: [SIMD3<Float>: Int] = [:]
            let corners = try STL.read(url)
            for t in stride(from: 0, to: corners.count, by: 3) {
                var tri = SIMD3<Int>()
                for c in 0..<3 {
                    let p = corners[t + c]
                    if index[p] == nil { index[p] = positions.count; positions.append(p) }
                    tri[c] = index[p]!
                }
                triangles.append(tri)
            }
        }

        /// Every edge between exactly two triangles, running opposite ways in them.
        var watertight: Bool {
            var directed = Set<SIMD2<Int>>(), undirected: [SIMD2<Int>: Int] = [:]
            for t in triangles {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    guard directed.insert([a, b]).inserted else { return false }
                    undirected[[min(a, b), max(a, b)], default: 0] += 1
                }
            }
            return undirected.values.allSatisfy { $0 == 2 }
        }

        var pieces: Int {
            var parent = Array(positions.indices)
            func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
            for t in triangles { parent[find(t.y)] = find(t.x); parent[find(t.z)] = find(t.x) }
            return Set(positions.indices.map(find)).count
        }

        var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>) { Mesh(positions: positions).bounds }

        /// Area of the triangles lying flat on the lowest z.
        var flatBottom: Float {
            let lo = bounds.lo.z
            return triangles.reduce(0) { sum, t in
                let a = positions[t.x], b = positions[t.y], c = positions[t.z]
                guard [a, b, c].allSatisfy({ abs($0.z - lo) < 1e-3 }) else { return sum }
                return sum + simd_length(simd_cross(b - a, c - a)) / 2
            }
        }
    }

    /// What the last `prep` logged.
    var logged: [String] = []

    func prep(_ extra: [String] = [], mesh: Mesh = fixture()) throws -> (Prep.Result, Printed, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let glb = dir.appendingPathComponent("fixture.glb"), stl = dir.appendingPathComponent("out.stl")
        try Self.glb(mesh, translation: [0.8, -0.5, 0]).write(to: glb)
        var lines: [String] = []
        let result = try Prep.run(PrepOptions.parse([glb.path, stl.path] + extra)) { lines.append($0) }
        logged = lines
        return (result, try Printed(stl), stl)
    }

    func testTheFixtureComesOutPrintable() throws {
        let (result, out, _) = try prep()
        let (lo, hi) = out.bounds
        XCTAssertTrue(out.watertight, "watertight: every edge between exactly two triangles")
        XCTAssertGreaterThan(out.flatBottom, 0.95 * .pi * 12.5 * 12.5, "flat bottom covers the 25 mm base")
        XCTAssertEqual(hi.z - lo.z, 32 + 3 - 0.6 - 0.4, accuracy: 0.3, "height 32 + 3 - 0.6 - 0.4 = 34 mm")
        // Where only the body exists: above the wisp (which reaches ~3 mm up) and below the blade
        // (from ~6 mm). Ground sits 2 mm above the bottom: 3 mm base, feet sunk 0.6, 0.4 sliced off.
        let ground = lo.z + 2
        let body = out.positions.filter { $0.z > ground + 3.6 && $0.z < ground + 5.6 }
        let centre = body.reduce(SIMD3<Float>(), +) / Float(body.count)
        XCTAssertLessThan(simd_length(SIMD2(centre.x, centre.y)), 0.5, "body centred on the base: \(centre)")
        XCTAssertEqual(out.pieces, 1, "one piece")
        XCTAssertGreaterThanOrEqual(result.dropped, 1, "the speck was a piece of its own, and was dropped")
        let above = out.positions.filter { $0.z > ground + 10 && $0.z < ground + 20 }
        XCTAssertLessThan(above.map(\.x).max()!, 14, "nothing left where the speck floated (x ≈ 18 mm)")
        // The blade reaches ~9.5 mm out, the body 4.3: the inflate kept it, attached.
        XCTAssertGreaterThan(above.map(\.x).max()!, 9, "the paper-thin blade survived")
        XCTAssertEqual(result.lines.count, 1, "no warning: the figure fits its base")
        XCTAssertTrue(result.lines[0].hasPrefix("mini_prep: "))
    }

    /// Every real mini is trimmed (millions of triangles down to 800,000); the collapses must
    /// keep it watertight and the bottom flat.
    func testTrimmingKeepsItPrintable() throws {
        let (_, out, _) = try prep(["--faces", "20000"])
        XCTAssertLessThanOrEqual(out.triangles.count, 20000)
        XCTAssertGreaterThan(out.triangles.count, 18000)
        XCTAssertTrue(out.watertight)
        XCTAssertEqual(out.pieces, 1)
        XCTAssertGreaterThan(out.flatBottom, 0.95 * .pi * 12.5 * 12.5)
    }

    /// A Pixal3D model faces away from the front render; --turn 180 turns it round without
    /// mirroring it: the blade that reached out to +x reaches to -x, and it's still one sound solid.
    func testTurningFacesTheFigureTheOtherWay() throws {
        let (_, out, _) = try prep(["--turn", "180", "--faces", "20000"])
        let ground = out.bounds.lo.z + 2
        let above = out.positions.filter { $0.z > ground + 10 && $0.z < ground + 20 }
        XCTAssertLessThan(above.map(\.x).min()!, -9, "the blade didn't come round to -x")
        XCTAssertLessThan(above.map(\.x).max()!, 6, "something still reaches out to +x")
        XCTAssertTrue(out.watertight, "a mirror instead of a turn would turn the triangles inside out")
        XCTAssertEqual(out.pieces, 1)
        XCTAssertEqual(try PrepOptions.parse(["a.glb", "b.stl", "--turn", "180"]).turn, 180)
    }

    /// Turn and levelling compose: an object turned 180° comes out as the same levelled solid
    /// turned round, not levelled against the wrong side.
    func testTurningAndLevellingCompose() throws {
        let (_, plain, _) = try prep(["--ground", "bottom", "--fit", "longest", "--faces", "20000"])
        let plainRest = logged.filter { $0.contains("stable side") }
        let (_, turned, _) = try prep(["--ground", "bottom", "--fit", "longest", "--turn", "180", "--faces", "20000"])
        let (a, b) = (plain.bounds, turned.bounds)
        XCTAssertEqual(b.lo.x, -a.hi.x, accuracy: 0.3); XCTAssertEqual(b.hi.x, -a.lo.x, accuracy: 0.3)
        XCTAssertEqual(b.lo.y, -a.hi.y, accuracy: 0.3); XCTAssertEqual(b.hi.y, -a.lo.y, accuracy: 0.3)
        XCTAssertEqual(b.hi.z - b.lo.z, a.hi.z - a.lo.z, accuracy: 0.2)
        XCTAssertTrue(turned.watertight)
        // As an object, the wisp hanging below its feet leaves it unable to stand (it rocks on
        // the wisp's tip), so both are left upright as made, neither levelled nor laid down.
        XCTAssertEqual(logged.filter { $0.contains("stable side") }, plainRest)
        XCTAssertEqual(plainRest.count, 0)
    }

    /// A held thing the generator didn't join to the figure (a Pixal3D elf's bow): a bar in
    /// front of the body, clear of it by far more than the inflate, and 1.2 of the 2.65 tall.
    /// It's left out, as a speck would be, but said, with how long it was.
    func testASeparatePartIsLeftOutAndSaid() throws {
        var m = Self.fixture()
        m.add(Self.box(half: [0.03, 0.03, 0.6]), at: [0, -0.55, 1.4])
        let (result, out, _) = try prep(["--faces", "20000"], mesh: m)
        let parts = result.lines.filter { $0.hasPrefix(Prep.partWarning) }
        XCTAssertEqual(parts.count, 1, "\(result.lines)")
        // 1.2 × (32 / 2.65) = 14.5 mm, plus the inflate at each end.
        XCTAssertTrue(parts.first?.contains("A part came out separate from the figure (about 15 mm long) and was left out.") == true, "\(parts)")
        XCTAssertTrue(parts.first?.hasSuffix("Try Make Another Version. If you use Pixal3D, TRELLIS.2 (Settings → 3D Model) joins held things more reliably.") == true)
        XCTAssertEqual(out.pieces, 1)
        let above = out.positions.filter { $0.z > out.bounds.lo.z + 5 }  // above the base
        XCTAssertGreaterThan(above.map(\.y).min()!, -6, "the bar (at y ≈ -6.6 mm) is out of the print file")
        XCTAssertEqual(result.lines.count, 2, "the fixture's speck said nothing")
        XCTAssertEqual(result.warnings.map(\.kind), [.part], "the job is told it too")
        XCTAssertEqual(result.warnings.map { Prep.partWarning + $0.text }, parts)
    }

    /// The report beside the print file reads back as written, and what it says comes to: the
    /// part and stand warnings said once each, and fragile from any other.
    func testThePrepReportBesideThePrintFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stl = dir.appendingPathComponent("elf.stl")
        XCTAssertEqual(PrepReport.file(beside: stl), dir.appendingPathComponent("prep-result.json"))
        XCTAssertNil(PrepReport.read(dir))
        let report = PrepReport(warnings: [.init(.footprint, "wide"), .init(.part, "A part."), .init(.stand, "Stand."), .init(.part, "A part.")])
        try report.write(beside: stl)
        XCTAssertEqual(PrepReport.read(dir), report)
        XCTAssertEqual(report.notes, ["A part.", "Stand."])
        XCTAssertTrue(report.fragile)
        XCTAssertFalse(PrepReport(warnings: [.init(.part, "A part."), .init(.stand, "Stand.")]).fragile)
        try PrepReport(failure: "flat").write(beside: stl)
        XCTAssertEqual(PrepReport.read(dir)?.failure, "flat")
    }

    /// The generator's figures are often hollow, and the solid's wall round the hollow is a
    /// piece of its own, bigger than any part (the elf's was its whole body's length). Dropping
    /// it fills the hollow, which is right, and says nothing: it's inside out, so its volume is
    /// negative. The hollow here is about 6 mm across, well over a tenth of the height.
    func testAHollowIsFilledWithoutAWarning() throws {
        var m = Self.fixture()
        var hollow = Self.sphere(radius: 0.25)
        hollow.triangles = hollow.triangles.map { SIMD3($0.x, $0.z, $0.y) }
        m.add(hollow, at: [0, 0, 1])
        let (result, out, _) = try prep(["--faces", "20000"], mesh: m)
        XCTAssertGreaterThanOrEqual(result.dropped, 2, "the hollow's wall and the speck were both pieces")
        XCTAssertEqual(result.lines.count, 1, "\(result.lines)")
        XCTAssertEqual(out.pieces, 1)
    }

    /// Real minis, opt-in (each is a 36 MB model.glb and a minute of debug-build prep):
    /// MIMIC_PREP_MINIS=<folder of .glb files>. A file named `*-part.glb` must warn of a part
    /// (the Pixal3D elf that lost its bow); every other must not (they drop only specks and
    /// hollows). Measured on seven: NOTES.md, "Pieces print prep leaves out".
    func testRealMinisWarnOnlyOfARealPart() throws {
        guard let folder = ProcessInfo.processInfo.environment["MIMIC_PREP_MINIS"] else { throw XCTSkip("set MIMIC_PREP_MINIS") }
        let glbs = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".glb") }.sorted()
        XCTAssertFalse(glbs.isEmpty)
        for name in glbs {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let result = try Prep.run(PrepOptions.parse([folder + "/" + name, dir.appendingPathComponent("out.stl").path]))
            let parts = result.lines.filter { $0.hasPrefix(Prep.partWarning) }
            XCTAssertEqual(parts.count, name.hasSuffix("-part.glb") ? 1 : 0, "\(name): \(result.lines)")
        }
    }

    /// JobRunner marks a mini fragile when its report has this warning.
    func testAFootprintWiderThanTheBaseWarns() throws {
        let (result, _, stl) = try prep(["--base", "8", "--faces", "20000"])
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("mini_prep: WARNING") }, "\(result.lines)")
        XCTAssertEqual(result.warnings.map(\.kind), [.footprint])
        let side = stl.deletingPathExtension().path + "_side.png"  // an older mini's one side view
        FileManager.default.createFile(atPath: side, contents: Data([1]))
        try Render.views(result.mesh, besides: stl)
        for view in ["front", "left", "right", "back"] {
            let png = stl.deletingPathExtension().path + "_\(view).png"
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual([image.width, image.height], [900, 900])
            XCTAssertEqual(image.alphaInfo, .last, "transparent background")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: side), "the old side view stayed beside left and right")
    }

    /// The previews are drawn before the print file is put in place (#172): when drawing them
    /// fails, or a resize is stopped meanwhile, the old print file stays, the size its settings say.
    func testAResizeWhosePreviewsFailKeepsTheOldPrintFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let glb = dir.appendingPathComponent("fixture.glb"), stl = dir.appendingPathComponent("out.stl")
        try Self.glb(Self.fixture(), translation: [0.8, -0.5, 0]).write(to: glb)
        try Data("old".utf8).write(to: stl)
        // A folder where the front view goes: it can't be written.
        let front = dir.appendingPathComponent("out_front.png")
        try FileManager.default.createDirectory(at: front, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: front.appendingPathComponent("keep").path, contents: Data())
        let options = try PrepOptions.parse([glb.path, stl.path, "--faces", "20000"])
        XCTAssertThrowsError(try Prep.run(options, views: true))
        XCTAssertEqual(try Data(contentsOf: stl), Data("old".utf8), "the new print file went in without its previews")
        // Drawn, they go in with it.
        try FileManager.default.removeItem(at: front)
        _ = try Prep.run(options, views: true)
        XCTAssertTrue(try Printed(stl).watertight)
        XCTAssertTrue(FileManager.default.fileExists(atPath: front.path))
    }

    /// A square base is its size along each side; a hex is its size across the flat sides, which
    /// face the figure's front and back (±y), and 2/√3 of it across the corners (±x). Measured
    /// through the middle of the base, below the feet and the rounded top edge.
    func testSquareAndHexBases() throws {
        let root3 = Float(3).squareRoot()
        let shapes: [(String, area: Float, x: Float, y: Float)] = [
            ("round", .pi * 156.25, 25, 25), ("square", 625, 25, 25), ("hex", 2 * root3 * 156.25, 50 / root3, 25)]
        for (shape, area, x, y) in shapes {
            let (result, out, _) = try prep(["--base-shape", shape, "--faces", "40000"])
            XCTAssertTrue(out.watertight, shape)
            XCTAssertEqual(out.pieces, 1, shape)
            XCTAssertEqual(result.mesh.section(1.3).area, area, accuracy: 3, shape)
            let base = out.positions.filter { $0.z < 1.9 }
            let xs: [Float] = base.map { $0.x }, ys: [Float] = base.map { $0.y }
            XCTAssertEqual(xs.max()! - xs.min()!, x, accuracy: 0.3, "\(shape) across x")
            XCTAssertEqual(ys.max()! - ys.min()!, y, accuracy: 0.3, "\(shape) across y")
        }
    }

    /// A magnet hole goes up into the base from underneath, a little wider and deeper than the
    /// magnet, on any shape of base, and the mini stays one watertight piece. Its depth counts
    /// from the bottom as printed, after 0.4 mm is sliced off: counted from the base's own
    /// underside, the hole would come out 0.4 mm too shallow for the magnet.
    func testAMagnetHoleUnderTheBase() throws {
        let hole = Float.pi * 2.6 * 2.6  // a 5 mm magnet, with 0.2 mm to spare
        let shapes: [(String, area: Float)] = [("round", .pi * 156.25), ("square", 625), ("hex", 2 * Float(3).squareRoot() * 156.25)]
        for (shape, area) in shapes {
            let (result, out, _) = try prep(["--base-shape", shape, "--magnet", "5x2", "--faces", "40000"])
            XCTAssertTrue(out.watertight, shape)
            XCTAssertEqual(out.pieces, 1, shape)
            XCTAssertEqual(result.mesh.section(0.1).area, area - hole, accuracy: 3, "\(shape): the hole opens at the bottom")
            XCTAssertEqual(result.mesh.section(2.05).area, area - hole, accuracy: 3, "\(shape): 2 mm deep and a little more")
            XCTAssertEqual(result.mesh.section(2.35).area, area, accuracy: 3, "\(shape): and no deeper")
            XCTAssertGreaterThan(out.flatBottom, 0.95 * (area - hole), "\(shape): still flat around it")
            let rim = out.positions.filter { $0.z < 1.5 && simd_length(SIMD2($0.x, $0.y)) < 5 }.map { simd_length(SIMD2($0.x, $0.y)) }
            XCTAssertEqual(rim.min()!, 2.6, accuracy: 0.1, "\(shape): 5.2 mm across")
        }
    }

    /// The default base is 2.6 mm once its bottom is sliced flat: too thin for a 3 mm magnet and
    /// barely deeper than a 2 mm one. With a magnet it's made taller, so 0.8 mm stays over the
    /// hole, and more on a floor, whose seams are cut 0.45 mm down into it. A base already tall
    /// enough is left as it is, and with no base there's nowhere for a hole, which is said.
    func testABaseIsMadeTallEnoughForItsMagnet() throws {
        let (result, out, _) = try prep(["--magnet", "8x3", "--faces", "40000"])
        let (lo, hi) = out.bounds
        XCTAssertTrue(out.watertight)
        XCTAssertEqual(out.pieces, 1)
        XCTAssertEqual(hi.z - lo.z, 32 + 4.4 - 0.6 - 0.4, accuracy: 0.3, "the base grew from 3 to 4.4 mm")
        let round = Float.pi * 156.25, hole = Float.pi * 4.1 * 4.1
        XCTAssertEqual(result.mesh.section(3.1).area, round - hole, accuracy: 4, "3 mm deep and a little more")
        XCTAssertEqual(result.mesh.section(3.3).area, round, accuracy: 4, "with a roof over it")
        XCTAssertTrue(result.lines.contains { $0.contains("magnet hole 8.2 mm wide, 3.2 mm deep") && $0.contains("base 4.40 mm tall") }, "\(result.lines)")
        XCTAssertFalse(result.lines.contains { $0.contains("WARNING") }, "a taller base is nothing to warn of")

        func height(_ flags: [String]) throws -> Double { try PrepOptions.parse(["a.glb", "b.stl"] + flags).effectiveBaseHeight }
        XCTAssertEqual(try height([]), 3, "no magnet, no change")
        XCTAssertEqual(try height(["--magnet", "5x2"]), 3.4, accuracy: 1e-9)
        XCTAssertEqual(try height(["--magnet", "5x2", "--base-style", "stone"]), 3.85, accuracy: 1e-6)
        XCTAssertEqual(try height(["--magnet", "5x2", "--base-height", "5"]), 5, "already tall enough")
        XCTAssertNil(try PrepOptions.parse(["a.glb", "b.stl", "--magnet", "5x2", "--no-base"]).hole)
        XCTAssertNil(try PrepOptions.parse(["a.glb", "b.stl", "--magnet", "none"]).magnet)
        XCTAssertEqual(try PrepOptions.parse(["a.glb", "b.stl", "--magnet", "6x2", "--nozzle", "0.6"]).hole?.width ?? 0, 6.3, accuracy: 1e-9,
                       "more room on a wide nozzle")
        XCTAssertThrowsError(try PrepOptions.parse(["a.glb", "b.stl", "--magnet", "10x5"]))
        let bare = try prep(["--magnet", "5x2", "--no-base", "--faces", "20000"]).0
        XCTAssertTrue(bare.lines.contains("mini_prep: no base, so no magnet hole"))
    }

    /// A floor is pressed into the top of the base: stones stand up to the plain top, seams go no
    /// deeper than 0.45 mm, so the feet (sunk 0.6 mm) are still one piece with the base; the
    /// bottom stays flat. The same seed lays the same floor, another seed another one.
    func testFloorsArePressedIntoTheBase() throws {
        let top: Float = 3 - 0.4  // the base's top, once 0.4 mm is sliced off the bottom
        for style in ["stone", "wood", "cobble"] {
            let (_, out, stl) = try prep(["--base-style", style, "--base-seed", "7", "--faces", "60000"])
            XCTAssertTrue(out.watertight, style)
            XCTAssertEqual(out.pieces, 1, "\(style): the figure is still one piece with its base")
            XCTAssertGreaterThan(out.flatBottom, 0.95 * .pi * 12.5 * 12.5, style)
            // The top of the base, away from the figure and the rounded edge.
            let floor = out.positions.filter {
                let r = simd_length(SIMD2($0.x, $0.y))
                return r > 7 && r < 11 && $0.z > 1.5 && $0.z < top + 0.3
            }
            let zs: [Float] = floor.map { $0.z }
            XCTAssertEqual(zs.max()!, top, accuracy: 0.05, "\(style): stones or planks reach the top")
            XCTAssertGreaterThan(zs.min()!, top - 0.5, "\(style): no seam deeper than the feet are sunk")
            XCTAssertLessThan(zs.min()!, top - 0.35, "\(style): the seams are cut")
            let again = try prep(["--base-style", style, "--base-seed", "7", "--faces", "60000"]).2
            XCTAssertEqual(try Data(contentsOf: again), try Data(contentsOf: stl), "\(style): the same seed, the same floor")
            let other = try prep(["--base-style", style, "--base-seed", "8", "--faces", "60000"]).2
            XCTAssertNotEqual(try Data(contentsOf: other), try Data(contentsOf: stl), "\(style): another seed, another floor")
        }
    }

    /// Planks run front to back: across them a seam every plank, along one hardly any.
    func testPlanksRunFrontToBack() {
        let f = Solid.Floor(.wood)
        func seams(_ point: (Float) -> (Float, Float)) -> Int {
            var n = 0, inSeam = false
            for t in stride(from: Float(-12), to: 12, by: 0.05) {
                let (x, y) = point(t)
                let now = Solid.relief(x, y, f) > 0.4
                if now && !inSeam { n += 1 }
                inSeam = now
            }
            return n
        }
        for x: Float in [-10, -5, 0, 5, 10] {
            for y: Float in [-9.1, 0.3, 3.7, 11] { XCTAssertGreaterThan(Solid.relief(x, y, f), 0.4, "a seam runs front to back at x = \(x)") }
        }
        XCTAssertLessThanOrEqual(seams { (2.5, $0) }, 2, "along a plank, 24 mm: only its ends, 20 mm apart")
    }

    /// Each view is the figure's own: facing -y, its left is +x. A figure with a nose (-y) and
    /// its left hand held out (+x): from the front the hand is on the picture's right, as when
    /// facing someone; from its left the nose points left, from its right it points right. The
    /// cross product rules out a mirrored picture, which the silhouettes alone can't.
    func testViewsShowTheFiguresOwnSides() {
        for c in Render.cameras {
            XCTAssertEqual(simd_cross(c.right, Render.up), c.toward, "\(c.0) is mirrored")
        }
        var m = Mesh()
        m.add(Self.box(half: [0.2, 0.2, 1]), at: [0, 0, 1])       // body
        m.add(Self.box(half: [0.1, 0.3, 0.1]), at: [0, -0.5, 1.6])  // nose
        m.add(Self.box(half: [0.3, 0.1, 0.1]), at: [0.5, 0, 1])    // left hand
        // Where the picture leans: the mean column of what's drawn, 0 being the body's middle.
        func lean(_ view: String) -> Float {
            let c = Render.cameras.first { $0.0 == view }!
            let rgba = Render.picture(m, m.vertexNormals(), mid: [0, 0, 1], span: 3, right: c.right, up: Render.up, toward: c.toward)
            var sum: Float = 0, count: Float = 0
            for i in stride(from: 3, to: rgba.count, by: 4) where rgba[i] > 0 {
                sum += Float((i / 4) % Render.size); count += 1
            }
            return sum / count - Float(Render.size) / 2
        }
        XCTAssertGreaterThan(lean("front"), 10, "the left hand isn't on the right from the front")
        XCTAssertLessThan(lean("back"), -10, "the left hand isn't on the left from behind")
        XCTAssertLessThan(lean("left"), -10, "the nose doesn't point left from the figure's left")
        XCTAssertGreaterThan(lean("right"), 10, "the nose doesn't point right from the figure's right")
    }

    /// The generated cube table on a random field, far harder than any figure: every one of the
    /// 256 corner patterns next to every other. (At 14³ it missed a fan whose diagonal lay on a
    /// cube face, which gave the dwarf 78 edges of four triangles; 40³ catches it.)
    func testTheCubeTableIsClosedForAnyField() {
        var rng = SplitMix(seed: 7)
        let n = 40
        var field = [Float](repeating: 1, count: n * n * n)
        for k in 1..<(n - 1) { for j in 1..<(n - 1) { for i in 1..<(n - 1) {
            field[(k * n + j) * n + i] = Float.random(in: 0.01...1, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        } } }
        let part = Solid.march(field, nx: n, ny: n, planes: n, k0: 0, origin: .zero, h: 1)
        var directed = Set<SIMD2<UInt32>>(), undirected: [SIMD2<UInt32>: Int] = [:], twice = 0
        var volume: Float = 0
        for t in part.triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                if !directed.insert([a, b]).inserted { twice += 1 }
                undirected[[min(a, b), max(a, b)], default: 0] += 1
            }
            volume += simd_dot(part.positions[Int(t.x)], simd_cross(part.positions[Int(t.y)], part.positions[Int(t.z)])) / 6
        }
        XCTAssertEqual(twice, 0, "edges running the same way in two triangles")
        XCTAssertEqual(undirected.values.filter { $0 != 2 }.count, 0, "edges not between exactly two triangles")
        XCTAssertGreaterThan(volume, 0, "wound outward")
    }

    /// An object lying flat: a long box with a spout sticking out of one end at mid-height, and
    /// a thin tip on that, and a speck floating far off to the side. Sized by its longest side
    /// (box, spout and tip, not the speck; a percentile of the surface trimmed the tip), standing
    /// on its whole bottom, centred on its whole shadow, spout included.
    func testAnObjectLyingFlatIsSizedByItsLongestSideAndStandsOnItsWholeBottom() throws {
        var m = Mesh()
        m.add(Self.box(half: [1, 0.25, 0.15]), at: [0, 0, 0.15])       // 2 x 0.5 x 0.3, lying flat
        m.add(Self.box(half: [0.3, 0.05, 0.05]), at: [1.25, 0, 0.2])   // spout: shadow reaches x = 1.55
        m.add(Self.sphere(radius: 0.02), at: [0, 3, 1])                // speck, 3 units off in y
        m.add(Self.box(half: [0.08, 0.015, 0.015]), at: [1.6, 0, 0.2]) // a thin tip, its own piece: shadow reaches x = 1.68
        let (result, out, _) = try prep(["--fit", "longest", "--ground", "bottom", "--height", "60", "--no-base"], mesh: m)
        let (lo, hi) = out.bounds
        let scale: Float = 60 / 2.68
        XCTAssertEqual(hi.x - lo.x, 60 + 2 * 0.16, accuracy: 0.6, "the longest side is 60 mm (plus the inflate)")
        XCTAssertEqual(hi.z - lo.z, 0.3 * scale + 0.16 - 0.4, accuracy: 0.3, "lying flat: its height is the box's, not 60 mm")
        XCTAssertEqual((lo.x + hi.x) / 2, 0, accuracy: 0.3, "centred on its whole shadow, spout included")
        XCTAssertEqual((lo.y + hi.y) / 2, 0, accuracy: 0.3)
        XCTAssertGreaterThan(out.flatBottom, 0.9 * 2 * 0.5 * scale * scale, "stands on its whole bottom")
        XCTAssertTrue(out.watertight)
        XCTAssertEqual(out.pieces, 1)
        XCTAssertGreaterThanOrEqual(result.dropped, 1, "the speck was dropped, and didn't count as its size")
        XCTAssertEqual(result.lines.count, 1)
    }

    /// An object the engine left leaning stands up straight on its bottom; a character, which
    /// stands on its feet, is left as it is.
    func testALeaningObjectIsLevelled() throws {
        var m = Mesh()
        m.add(Self.box(half: [1, 0.6, 0.4]), at: [0, 0, 0.4])
        let lean = simd_quatf(angle: 12 * .pi / 180, axis: simd_normalize(SIMD3<Float>(1, 0.4, 0)))
        m.positions = m.positions.map { lean.act($0) }
        let (result, out, _) = try prep(["--fit", "longest", "--ground", "bottom", "--height", "40", "--no-base"], mesh: m)
        let scale: Float = 40 / 2
        XCTAssertGreaterThan(out.flatBottom, 0.9 * 2 * 1.2 * scale * scale, "stands on its whole bottom, not an edge")
        XCTAssertEqual(out.bounds.hi.z - out.bounds.lo.z, 0.8 * scale + 0.16 - 0.4, accuracy: 0.4, "upright: its height is the box's")
        XCTAssert(result.lines.isEmpty == false)

        var tipped = m
        XCTAssertEqual(tipped.level(), 12, accuracy: 0.5, "reads the lean")
        var onItsSide = Mesh()
        onItsSide.add(Self.box(half: [1, 0.6, 0.4]), at: [0, 0, 0.4])
        let side = simd_quatf(angle: 50 * .pi / 180, axis: [1, 0, 0])
        onItsSide.positions = onItsSide.positions.map { side.act($0) }
        XCTAssertEqual(onItsSide.level(), 0, "past 30° it's left alone")
    }

    // MARK: Setting an object on a side it can stand on

    static func turned(_ m: Mesh, _ degrees: Float, about axis: SIMD3<Float>) -> Mesh {
        var m = m
        let q = simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(axis))
        m.positions = m.positions.map { q.act($0) }
        return m
    }

    /// A frustum: a closed cylinder whose top is `top` times as wide as its bottom.
    static func frustum(radius: Float, top: Float, depth: Float) -> Mesh {
        var m = cylinder(radius: radius, depth: depth)
        m.positions = m.positions.map { $0.z > 0 ? SIMD3($0.x * top, $0.y * top, $0.z) : $0 }
        return m
    }

    /// What the last `prepObject` said to the person.
    var said: [String] = []

    func prepObject(_ m: Mesh) throws -> (Printed, Bool) {
        let (result, out, _) = try prep(["--fit", "longest", "--ground", "bottom", "--height", "60", "--no-base", "--faces", "20000"], mesh: m)
        said = result.lines.filter { $0.hasPrefix(Prep.standWarning) }
        XCTAssertEqual(result.warnings.filter { $0.kind == .stand }.map { Prep.standWarning + $0.text }, said, "the job is told what the log says")
        return (out, logged.contains { $0.hasPrefix("prep: set on its most stable side") })
    }

    /// A box lying at 50°, past what levelling straightens, has no side near its bottom to stand
    /// on: it is left as the engine made it, and the person told it needs a base.
    func testABoxOnItsEdgeIsLeftAsMadeAndSaid() throws {
        var m = Mesh()
        m.add(Self.box(half: [1, 0.6, 0.4]), at: [0, 0, 0])
        let (out, turned) = try prepObject(Self.turned(m, 50, about: [1, 0, 0]))
        XCTAssertFalse(turned, "\(logged)")
        XCTAssertEqual(said.count, 1, "\(said)")
        XCTAssertLessThan(out.flatBottom, 0.3 * 2 * 1.2 * 30 * 30, "still on its edge")
        XCTAssertTrue(out.watertight)
    }

    /// A box 4 times as tall as wide stands on its end, and stays standing: it can be tilted
    /// 14° before it tips, and a vase or a tower is meant to stand. One 8 times as tall (7.1°)
    /// can't stand on its end, but stays standing as made and is said to need a base.
    func testATallBoxStandsAndASpindlyOneIsSaid() throws {
        var tall = Mesh()
        tall.add(Self.box(half: [0.25, 0.25, 1]), at: [0, 0, 1])
        var (out, turned) = try prepObject(tall)
        XCTAssertFalse(turned, "\(logged)")
        XCTAssertEqual(out.bounds.hi.z - out.bounds.lo.z, 60 + 0.16 - 0.4, accuracy: 0.4, "standing")


        var spindly = Mesh()
        spindly.add(Self.box(half: [0.25, 0.25, 2]), at: [0, 0, 2])
        (out, turned) = try prepObject(spindly)
        XCTAssertFalse(turned, "\(logged)")
        XCTAssertEqual(said.count, 1, "\(said)")
        XCTAssertEqual(out.bounds.hi.z - out.bounds.lo.z, 60 + 0.16 - 0.4, accuracy: 0.4, "standing")
    }

    /// A teapot upside down on its lid's knob (it tips at 5°) is left as it is: turning it over
    /// is further than `rest` goes, since the engine keeps the picture's up. A cup upside down on
    /// its wide rim stands there: like a vase, it isn't the steadier side that decides, only
    /// whether it can stand.
    func testAnUpsideDownTeapotAndCupAreLeftAsTheyAre() throws {
        var pot = Mesh()
        pot.add(Self.cylinder(radius: 0.5, depth: 0.6), at: [0, 0, 0.3])       // body on a flat base
        pot.add(Self.cylinder(radius: 0.05, depth: 0.2), at: [0, 0, 0.65])    // the knob
        pot.add(Self.box(half: [0.2, 0.06, 0.06]), at: [0.65, 0, 0.4])          // spout
        pot.add(Self.box(half: [0.08, 0.03, 0.15]), at: [-0.55, 0, 0.35])       // handle
        var upside = Self.turned(pot, 180, about: [1, 0.2, 0])
        let turnedOver = upside.positions
        XCTAssertEqual(upside.level(), 0)
        XCTAssertNil(upside.rest())
        XCTAssertEqual(upside.positions, turnedOver, "untouched")
        var upright = pot
        XCTAssertEqual(upright.rest(), 0, "a teapot on its base stays")
        XCTAssertEqual(upright.positions, pot.positions, "untouched")

        var cup = Self.turned(Self.frustum(radius: 0.3, top: 5.0 / 3, depth: 0.8), 180, about: [1, 0, 0])
        let before = cup.positions
        XCTAssertEqual(cup.rest(), 0)
        XCTAssertEqual(cup.positions, before)
    }

    /// Only objects: a character lying down is left lying, exactly as before.
    func testACharacterIsNeverTurned() throws {
        let (_, out, _) = try prep(["--faces", "20000"], mesh: Self.turned(Self.fixture(), 90, about: [1, 0, 0]))
        XCTAssertFalse(logged.contains { $0.contains("stable side") }, "\(logged)")
        let (lo, hi) = out.bounds
        XCTAssertGreaterThan(hi.y - lo.y, 2 * (hi.z - lo.z), "still lying down")
    }

    /// A flat sheet from the engine (what a flat cartoon can come back as) fails, not a finished mini.
    func testAFlatSheetFails() throws {
        var quad = Mesh()
        quad.positions = [[-1, 0, 0], [1, 0, 0], [1, 0, 2], [-1, 0, 2]]
        quad.triangles = [[0, 1, 2], [0, 2, 3]]
        XCTAssertThrowsError(try prep(["--fit", "longest", "--ground", "bottom"], mesh: quad)) {
            XCTAssertTrue("\($0)".contains("came out flat"), "\($0)")
        }
    }

    /// Existing minis and jobs are untouched: no flags means exactly what the explicit
    /// character flags make, byte for byte.
    func testCharacterDefaultsAreTheExplicitDefaults() throws {
        let (_, _, plain) = try prep(["--faces", "20000"])
        let (_, _, explicit) = try prep(["--faces", "20000", "--fit", "height", "--ground", "feet"])
        XCTAssertEqual(try Data(contentsOf: plain), try Data(contentsOf: explicit))
    }

    func testOptionsAndTheirDefaults() throws {
        let o = try PrepOptions.parse(["a.glb", "b.stl"])
        XCTAssertEqual([o.height, o.base, o.baseHeight, o.nozzle, o.flatten], [32, 25, 3, 0.4, 0.4])
        XCTAssertEqual([o.effectiveInflate, o.effectiveVoxel], [0.16, 0.1])
        XCTAssertEqual(o.faces, 800_000)
        XCTAssertFalse(o.noBase)
        XCTAssertFalse(o.fitLongest || o.groundBottom)
        let object = try PrepOptions.parse(["a.glb", "b.stl", "--fit", "longest", "--ground", "bottom"])
        XCTAssertTrue(object.fitLongest && object.groundBottom)
        XCTAssertThrowsError(try PrepOptions.parse(["a.glb", "b.stl", "--fit", "widest"]))
        XCTAssertThrowsError(try PrepOptions.parse(["a.glb", "b.stl", "--ground"]))
        let fine = try PrepOptions.parse(["--height", "100.0", "a.glb", "--nozzle", "0.2", "--no-base", "b.stl", "--inflate", "0"])
        XCTAssertEqual([fine.height, fine.effectiveInflate, fine.effectiveVoxel], [100, 0, 0.05])
        XCTAssertTrue(fine.noBase)
        XCTAssertThrowsError(try PrepOptions.parse(["a.glb", "b.stl", "--height", "tall"]))
        XCTAssertThrowsError(try PrepOptions.parse(["a.glb", "b.stl", "--sideways"]))
        XCTAssertThrowsError(try PrepOptions.parse(["a.glb"]))
    }

    /// The reader turns glTF's y-up into z-up and applies the node's placement.
    func testTheGLBReaderPlacesAndTurns() throws {
        let tri = Mesh(positions: [[0, 0, 0], [1, 0, 0], [0, 0, 1]], triangles: [[0, 1, 2]])
        let read = try GLB.parse(Self.glb(tri, translation: [5, 6, 7]))
        XCTAssertEqual(read.positions, [[5, 6, 7], [6, 6, 7], [5, 6, 8]])
        XCTAssertEqual(read.triangles, [[0, 1, 2]])
        XCTAssertThrowsError(try GLB.parse(Data("not a model".utf8)))
    }

    /// Trimming a 960-triangle ball to 300 keeps it one closed ball: every edge between exactly
    /// two triangles, facing opposite ways, and still a sphere's count of corners for its faces
    /// (V - E + F = 2: 152 corners for 300 faces). Its volume barely moves. One already under
    /// the target is left as it is.
    func testDecimateKeepsTheBallClosed() {
        let ball = Self.sphere(radius: 10)
        XCTAssertEqual(ball.triangles.count, 960)
        let volume = { (m: Mesh) in Filament.volume(m.triangles.flatMap { t in [t.x, t.y, t.z].map { m.positions[Int($0)] } }) }

        let trimmed = Decimate.run(ball, target: 300)
        XCTAssertEqual(trimmed.triangles.count, 300, "each collapse takes two triangles, from an even count")
        XCTAssertEqual(trimmed.positions.count, 152)
        var edges: [SIMD2<UInt32>: Int] = [:]
        for t in trimmed.triangles {
            XCTAssert(t.x != t.y && t.y != t.z && t.z != t.x, "a triangle with a corner twice: \(t)")
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { edges[SIMD2(a, b), default: 0] += 1 }
        }
        XCTAssertEqual(edges.count, 900, "450 edges, each once in each direction")
        XCTAssertTrue(edges.allSatisfy { $0.value == 1 && edges[SIMD2($0.key.y, $0.key.x)] == 1 }, "an edge isn't between exactly two triangles")
        XCTAssertEqual(volume(trimmed), volume(ball), accuracy: volume(ball) * 0.08)

        let kept = Decimate.run(ball, target: 1000)
        XCTAssertEqual(kept.triangles.count, 960)
        XCTAssertEqual(kept.positions.count, ball.positions.count)
        XCTAssertEqual(volume(kept), volume(ball), accuracy: 1e-6)
    }
}

extension Mesh {
    mutating func add(_ other: Mesh, at offset: SIMD3<Float>) {
        let base = UInt32(positions.count)
        positions += other.positions.map { $0 + offset }
        triangles += other.triangles.map { $0 &+ base }
    }
}

/// Repeatable random numbers.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
