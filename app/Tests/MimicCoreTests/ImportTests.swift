import Foundation
import simd
import XCTest
@testable import MimicCore

/// Import Model (#96): a GLB or STL made elsewhere becomes a mini that only print prep runs on.
final class ImportTests: XCTestCase {
    let sizes = Sizes(height: "32", nozzle: "0.4")
    let fm = FileManager.default

    func temporary() throws -> URL {
        let d = fm.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// STL.write keeps no corner shared, as HeroForge's and every STL's triangles are.
    func stl(_ mesh: Mesh, in dir: URL, _ name: String = "model.stl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try STL.write(mesh, to: url)
        return url
    }

    func testACubesSeparateTrianglesAreJoinedAtTheirCorners() throws {
        let cube = PrepTests.box(half: [1, 2, 3])
        let corners = cube.triangles.flatMap { [cube.positions[Int($0.x)], cube.positions[Int($0.y)], cube.positions[Int($0.z)]] }
        XCTAssertEqual(corners.count, 36)
        let joined = ModelImport.weld(corners)
        XCTAssertEqual(joined.positions.count, 8)
        XCTAssertEqual(joined.triangles.count, 12)
        // Written and read back as floats, a corner can come back a hair off: still the same corner.
        let jittered = corners.enumerated().map { $0.element + SIMD3(repeating: $0.offset % 2 == 0 ? 1e-7 : 0) }
        XCTAssertEqual(ModelImport.weld(jittered).positions.count, 8)
        // A sliver (two corners in one place) has no area to print.
        let sliver: [SIMD3<Float>] = [[0, 0, 0], [0, 0, 0], [1, 0, 0]]
        XCTAssertEqual(ModelImport.weld(corners + sliver).triangles.count, 12)
    }

    func testTheModelWrittenIsReadBackTheSame() throws {
        let mesh = PrepTests.fixture()
        let back = try GLB.parse(GLB.encode(mesh))
        XCTAssertEqual(back.positions, mesh.positions, "z up in, z up out: the turn glTF's y up needs undid itself")
        XCTAssertEqual(back.triangles, mesh.triangles)
    }

    func testATextSTLReads() throws {
        let dir = try temporary()
        let cube = PrepTests.box(half: [5, 10, 20])
        var text = "solid cube\n"
        for t in cube.triangles {
            text += "  facet normal 0 0 0\n    outer loop\n"
            for i in [t.x, t.y, t.z] { let p = cube.positions[Int(i)]; text += "      vertex \(p.x) \(p.y) \(p.z)\n" }
            text += "    endloop\n  endfacet\n"
        }
        text += "endsolid cube\n"
        let url = dir.appendingPathComponent("cube.stl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let mesh = try GLB.parse(ModelImport.read(url).glb)
        XCTAssertEqual(mesh.positions.count, 8)
        XCTAssertEqual(mesh.triangles.count, 12)
        XCTAssertEqual(mesh.bounds.hi.z - mesh.bounds.lo.z, 40, accuracy: 1e-5, "z up, as slicers take an STL")
        XCTAssertEqual(mesh.bounds.hi.y - mesh.bounds.lo.y, 20, accuracy: 1e-5)
    }

    /// The point of joining the corners: print prep finds a model's main pieces (what an object
    /// is sized by and stands on) by shared corners, and of separate triangles finds none.
    func testAnImportedSTLComesOutPrintable() throws {
        let dir = try temporary()
        let read = try ModelImport.read(stl(PrepTests.fixture(), in: dir))
        XCTAssertTrue(try GLB.parse(read.glb).mainTriangles().contains(true), "no main piece: the corners weren't joined")
        let glb = dir.appendingPathComponent("model.glb"), out = dir.appendingPathComponent("out.stl")
        try read.glb.write(to: glb)
        let result = try Prep.run(PrepOptions.parse([glb.path, out.path])) { _ in }
        let printed = try PrepTests.Printed(out)
        XCTAssertTrue(printed.watertight)
        XCTAssertEqual(printed.pieces, 1)
        XCTAssertEqual(printed.bounds.hi.z - printed.bounds.lo.z, 32 + 3 - 0.6 - 0.4, accuracy: 0.3, "sized as asked, base included")
        XCTAssertGreaterThanOrEqual(result.dropped, 1, "the speck was still left out")
        XCTAssertTrue(read.note?.contains("inches") == true, "the fixture is 2.65 units tall: \(read.note ?? "no note")")
    }

    func testAModelThatDoesntLookLikeMillimetresIsSaidInTheLog() {
        func note(_ tall: Float) -> String? { ModelImport.unitsNote(PrepTests.box(half: [tall / 8, tall / 8, tall / 2])) }
        XCTAssertNil(note(32))
        XCTAssertNil(note(5.5))
        XCTAssertNil(note(480))
        XCTAssertTrue(note(0.032)?.contains("metres") == true)
        XCTAssertTrue(note(1.26)?.contains("inches") == true)
        XCTAssertTrue(note(3200)?.contains("smaller than millimetres") == true)
        XCTAssertFalse(note(1.26)?.contains("WARNING") ?? true, "a WARNING line would mark the mini fragile")
    }

    func testImportMakesAMiniThatOnlyPrintPrepRunsOn() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let file = try stl(PrepTests.box(half: [8, 8, 16]), in: fx.root, "Ogre Chief.stl")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        // No 3D engine or model downloaded: import doesn't need one.
        try jobs.importModel(file, name: "ogre-chief", shown: "Ogre Chief", sizes: sizes, kind: .object)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.kind, .prep)
        XCTAssertEqual(jobs.status?.succeeded, true)

        let d = runs.appendingPathComponent("ogre-chief")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: d.path).filter { !$0.hasSuffix(".log") }.sorted(), ["model.glb", "settings.json"])
        XCTAssertEqual(try GLB.read(d.appendingPathComponent("model.glb")).positions.count, 8, "joined before it was kept")
        let mini = try XCTUnwrap(Gallery.list(runs).first)
        XCTAssertEqual(mini.displayName, "Ogre Chief")
        XCTAssertEqual(mini.settings.imported, "Ogre Chief.stl")
        XCTAssertEqual(mini.settings.kind, .object)
        XCTAssertEqual(mini.settings.made, sizes)
        XCTAssertNil(mini.settings.source)
        XCTAssertNil(mini.settings.model)
        XCTAssertTrue(mini.hasModel)

        // Nothing to make it again from, and each refusal says why.
        XCTAssertFalse(JobRunner.canMakeAnotherVersion(mini))
        XCTAssertFalse(JobRunner.canMakeNewShape(mini))
        XCTAssertNil(MakeForm.again(mini, install: fx.install, card: SizeCard(purpose: .game, nozzle: "0.4", kind: .character)))
        XCTAssertThrowsError(try jobs.makeAnotherVersion(of: "ogre-chief")) { XCTAssertEqual($0 as? RequestError, .imported("ogre-chief")) }
        XCTAssertThrowsError(try jobs.makeNewShape(of: "ogre-chief")) { XCTAssertEqual($0 as? RequestError, .imported("ogre-chief")) }
        XCTAssertThrowsError(try jobs.retry(name: "ogre-chief")) { XCTAssertEqual($0 as? RequestError, .imported("ogre-chief")) }

        // Resize and Duplicate work, and the copy is imported too.
        try jobs.resize(name: "ogre-chief", sizes: Sizes(height: "60", nozzle: "0.4"))
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.succeeded, true)
        try jobs.duplicate("ogre-chief", as: "ogre-chief-2", shown: "Ogre Chief 2")
        XCTAssertEqual(MiniSettings.load(runs.appendingPathComponent("ogre-chief-2")).imported, "Ogre Chief.stl")
    }

    /// Never turned, even if a model were recorded: TRELLIS.2's turn is for what TRELLIS.2 made.
    func testAnImportedModelIsNeverTurned() throws {
        let fx = try Fixture()
        var s = MiniSettings(); s.imported = "dragon.glb"; s.requested = sizes; s.model = "trellis2-q8"
        guard case let .run(_, args, _, _) = try Pipeline.plan(.prep, folder: fx.install.runs.appendingPathComponent("dragon"), settings: s,
                                                              tools: fx.tools()).last!.step else { return XCTFail() }
        XCTAssertFalse(args.contains("--turn"), "\(args)")
        XCTAssertThrowsError(try Pipeline.plan(.generate, folder: fx.install.runs.appendingPathComponent("dragon"), settings: s, tools: fx.tools()))
    }

    /// A GLB keeps its shape and its place, and is joined at its corners too: this one has every
    /// triangle's corners apart, as a GLB with no index list or split at every face has.
    func testAGLBKeepsItsShapeAndIsJoined() throws {
        let fx = try Fixture()
        let cube = PrepTests.box(half: [5, 10, 20])
        let apart = Mesh(positions: cube.triangles.flatMap { [cube.positions[Int($0.x)], cube.positions[Int($0.y)], cube.positions[Int($0.z)]] },
                         triangles: (0..<UInt32(cube.triangles.count)).map { SIMD3($0 * 3, $0 * 3 + 1, $0 * 3 + 2) })
        let file = fx.root.appendingPathComponent("dwarf.glb")
        try PrepTests.glb(apart, translation: [0.8, -0.5, 0]).write(to: file)
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        try jobs.importModel(file, name: "dwarf", sizes: sizes)
        jobs.waitUntilDone()
        let kept = try GLB.read(fx.install.runs.appendingPathComponent("dwarf/model.glb"))
        XCTAssertEqual(kept.positions.count, 8)
        XCTAssertEqual(kept.triangles.count, 12)
        XCTAssertEqual(kept.bounds.lo.x, -5 + 0.8, accuracy: 1e-5, "moved by its node, as it was")
        XCTAssertEqual(kept.bounds.hi.z, 20, accuracy: 1e-5, "z up after the GLB's y up, as the 3D engine's are read")
    }

    func testAFileThatIsntAModelWritesNothing() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        for (name, bytes) in [("broken.stl", Data("not a model at all".utf8)), ("broken.glb", Data(repeating: 7, count: 200)),
                              ("dwarf.obj", Data("v 0 0 0".utf8))] {
            let file = fx.root.appendingPathComponent(name)
            try bytes.write(to: file)
            XCTAssertThrowsError(try jobs.importModel(file, name: "broken", sizes: sizes), name) { error in
                guard case .unreadableModel = error as? RequestError else { return XCTFail("\(name): \(error)") }
            }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: runs.path).filter { !$0.hasPrefix(".") }, [], "a folder was left behind")
        XCTAssertTrue(JobQueue(runs: runs).entries().isEmpty)
    }

    func testANameInUseIsRefused() throws {
        let fx = try Fixture()
        _ = try fx.mini("ogre")
        let file = try stl(PrepTests.box(half: [8, 8, 16]), in: fx.root)
        XCTAssertThrowsError(try JobRunner(install: fx.install, tools: fx.tools()).importModel(file, name: "ogre", sizes: sizes)) {
            XCTAssertEqual($0 as? RequestError, .nameTaken("ogre"))
        }
    }

    func testTheNameComesFromTheFile() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let file = fx.root.appendingPathComponent("Ogre Chief.stl")
        XCTAssertTrue(ModelImport.names(for: file, in: runs) == ("Ogre Chief", "ogre-chief"))
        _ = try fx.mini("ogre-chief")
        XCTAssertTrue(ModelImport.names(for: file, in: runs) == ("Ogre Chief 2", "ogre-chief-2"))
        XCTAssertTrue(ModelImport.names(for: fx.root.appendingPathComponent("dwarf_cleric.glb"), in: runs) == ("Dwarf Cleric", "dwarf-cleric"))
    }

    func testMadeFromSaysImportedAndNoModel() {
        var s = MiniSettings(); s.imported = "ogre.stl"; s.requested = sizes
        let rows = MadeFrom(s, created: .distantPast).rows.map { "\($0.label): \($0.value)" }
        XCTAssertEqual(rows, ["Made from: A 3D model you imported"])
    }
}
