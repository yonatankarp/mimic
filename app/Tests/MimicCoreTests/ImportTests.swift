import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers
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

    /// Export for Virtual Tabletop (#158): in metres, within its budget, and facing glTF's front
    /// (+z), which `parse` reads back as -y: the print file's own front.
    func testATabletopExportIsInMetresFacingFront() throws {
        let d = try temporary()
        var mesh = Mesh()
        mesh.add(PrepTests.sphere(radius: 10), at: [0, 0, 10])
        mesh.add(PrepTests.box(half: [2, 5, 2]), at: [0, -15, 10])  // a nose, out the front
        try STL.write(mesh, to: d.appendingPathComponent("m.stl"))
        let glb = d.appendingPathComponent("m.glb")
        let made = try Tabletop.export(d.appendingPathComponent("m.stl"), to: glb, triangles: 100)
        let back = try GLB.read(glb)
        XCTAssertLessThanOrEqual(made.triangles, 100)
        XCTAssertEqual(back.triangles.count, made.triangles)
        XCTAssertEqual(back.bounds.lo.y, -0.020, accuracy: 1e-4, "the nose faces glTF's front")
        XCTAssertEqual(back.bounds.hi.y, 0.010, accuracy: 1e-3)
        XCTAssertEqual(back.bounds.lo.z, 0, accuracy: 1e-4, "stands on the ground")
        XCTAssertEqual(back.bounds.hi.z, 0.020, accuracy: 1e-3)
    }

    /// A 100 mm mini's print file, on prep's 0.1 mm grid, keeps tunnels too small to see (here a
    /// grate of 100 holes, 0.25 mm wide), and the trim never closes one: each kept a ring of
    /// triangles, so the export went over its budget and spent it on the base's rim and the
    /// wings instead (5,854 triangles, no base, at 100 mm). The tunnels close first now.
    func testABigMinisTinyTunnelsDontCostTheTabletopExportItsBase() throws {
        let d = try temporary()
        var parts = Mesh()
        parts.add(PrepTests.box(half: [1, 1, 49]), at: [0, 0, 51])  // a staff, up to 100 mm
        for k in 0...10 {  // a grate held out to the side: bars 0.3 mm wide, 0.25 mm apart, 10 × 10 holes
            let at = -2.75 + 0.55 * Float(k)
            parts.add(PrepTests.box(half: [2.9, 0.15, 0.15]), at: [3.8, 0, 80 + at])
            parts.add(PrepTests.box(half: [0.15, 0.15, 2.9]), at: [3.8 + at, 0, 80])
        }
        let base = Solid.Base(radius: 10, height: 2, bevel: 0.6)
        let print = Solid(mesh: parts, voxel: 0.1, inflate: 0, base: base, cut: 0).surface(parts).largestPiece().0
        try STL.write(print, to: d.appendingPathComponent("m.stl"))

        let glb = d.appendingPathComponent("m.glb")
        let made = try Tabletop.export(d.appendingPathComponent("m.stl"), to: glb, triangles: 1000)
        XCTAssertLessThanOrEqual(made.triangles, 1000)
        let back = try GLB.read(glb)
        // The base's underside, 20 mm across, still there (z up again in `read`, in metres).
        let bottom = back.positions.filter { $0.z < 0.0005 }
        let across = (bottom.map(\.x).max() ?? 0) - (bottom.map(\.x).min() ?? 0)
        XCTAssertEqual(across, 0.020, accuracy: 0.001, "the base's disc is gone")
        XCTAssertEqual(back.bounds.hi.z, 0.100, accuracy: 0.001)
    }

    /// A print file made before 0.10.0 faces +y (#275): the export turns it round, so it still
    /// faces glTF's front.
    func testAnOldPrintFileIsExportedFacingFrontToo() throws {
        let d = try temporary().appendingPathComponent("dwarf")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var mesh = Mesh()
        mesh.add(PrepTests.sphere(radius: 10), at: [0, 0, 10])
        mesh.add(PrepTests.box(half: [2, 5, 2]), at: [0, 15, 10])  // a nose, out the front at +y
        try STL.write(mesh, to: d.appendingPathComponent("dwarf.stl"))
        let old = Mini(name: "dwarf", folder: d, madeAt: Mini.facingFrontSince.addingTimeInterval(-60))
        XCTAssertTrue(old.facesAway)
        let glb = d.appendingPathComponent("dwarf.glb")
        try Tabletop.export(old, to: glb, triangles: 100)
        let back = try GLB.read(glb)
        XCTAssertEqual(back.bounds.lo.y, -0.020, accuracy: 1e-4, "the nose faces glTF's front")
        XCTAssertEqual(back.bounds.hi.y, 0.010, accuracy: 1e-3)
    }

    /// The colours come from the nearest point of the engine's model (#256): a sphere painted red
    /// above its middle and blue below comes out so on the triangles that cover it, through the
    /// .glb's own places on its picture, which a .glb written with them reads back.
    func testTheTabletopColoursComeFromTheNearestPointOfTheModel() throws {
        let sphere = PrepTests.sphere(radius: 10)
        // Each corner's place on a 1 × 2 picture: red on top, blue below.
        let uv = sphere.positions.map { SIMD2<Float>(0.5, $0.z > 0 ? 0.25 : 0.75) }
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let png = NSMutableData()
        let image = CGImage(width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let read = try GLB.parse(GLB.encode(sphere, paint: (uv, png as Data)), painted: true)
        let paint = try XCTUnwrap(read.paint, "a .glb written with a picture reads back with it")
        XCTAssertEqual(paint.uv, uv)

        let low = Decimate.run(sphere, target: 100)
        let size = 256
        let baked = try Tabletop.bake(low, EngineColours(model: read.mesh, paint: paint, toPrint: matrix_identity_double4x4), size: size)
        XCTAssertEqual(baked.mesh.triangles.count, low.triangles.count)
        var checked = 0
        for t in baked.mesh.triangles {
            let corners = [t.x, t.y, t.z].map { Int($0) }
            let z = corners.map { baked.mesh.positions[$0].z }.reduce(0, +) / 3
            guard abs(z) > 3 else { continue }  // clear of the middle
            let at = corners.map { baked.uv[$0] }.reduce(.zero, +) / 3 * Float(size)
            let o = 4 * (Int(at.y) * size + Int(at.x))
            let rgb = Array(baked.pixels[o..<o + 3])
            XCTAssertEqual(rgb, z > 0 ? [255, 0, 0] : [0, 0, 255], "at z \(z)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)
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

    /// Never turned, even if a model were recorded: Pixal3D's turn is for what Pixal3D made.
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
        XCTAssertTrue(JobQueue(folder: fx.install.queue).entries().isEmpty)
    }

    /// Taken out of the queue before its print file is made, an import goes to the Trash, as a
    /// waiting new mini does, instead of staying as a mini that never finishes. A resize of one
    /// already made, taken out, leaves it alone.
    func testRemovingAWaitingImportTrashesIt() throws {
        let fx = try Fixture(); _ = try fx.mini("first")
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 1")), trash: { spy($0) })
        try jobs.resize(name: "first", sizes: sizes)
        let file = try stl(PrepTests.box(half: [8, 8, 16]), in: fx.root)
        XCTAssertEqual(try jobs.importModel(file, name: "ogre", sizes: sizes), 1)
        XCTAssertTrue(try jobs.remove("ogre"))
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["ogre"])
        jobs.waitUntilDone()

        // Made (its print file there), then resized and taken out: kept.
        try jobs.importModel(file, name: "ogre-2", sizes: sizes)
        jobs.waitUntilDone()
        let made = fx.install.runs.appendingPathComponent("ogre-2")
        fm.createFile(atPath: made.appendingPathComponent("ogre-2.stl").path, contents: Data("stl".utf8))
        try jobs.resize(name: "first", sizes: Sizes(height: "40", nozzle: "0.4"))
        XCTAssertEqual(try jobs.resize(name: "ogre-2", sizes: Sizes(height: "60", nozzle: "0.4")), 1)
        XCTAssertTrue(try jobs.remove("ogre-2"))
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["ogre"], "a made import was trashed for a resize taken out")
        jobs.waitUntilDone()
    }

    /// A waiting new mini taken out goes to the Trash while the queue is still locked, so a make
    /// with the same name from another Mimic can't take its folder over in between (#179).
    func testAWaitingNewMiniIsTrashedUnderTheQueuesLock() throws {
        let fx = try Fixture(); _ = try fx.mini("first")
        let held = Flag(false)
        let lockFile = JobQueue(folder: fx.install.queue).lockFile
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 1")), trash: { _ in
            let fd = JobQueue.openLock(lockFile)
            defer { close(fd) }
            held.value = flock(fd, LOCK_EX | LOCK_NB) != 0
        })
        try jobs.resize(name: "first", sizes: sizes)
        XCTAssertEqual(try jobs.importModel(try stl(PrepTests.box(half: [8, 8, 16]), in: fx.root), name: "ogre", sizes: sizes), 1)
        XCTAssertTrue(try jobs.remove("ogre"))
        XCTAssertTrue(held.value, "trashed after the queue's lock was let go")
        jobs.waitUntilDone()
    }

    /// Stopped before its print file is made, an import goes to the Trash as a new mini does.
    func testStoppingAnImportTrashesIt() throws {
        let fx = try Fixture()
        let spy = TrashSpy()
        let started = fx.root.appendingPathComponent("started").path
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "touch \(started); sleep 5")), trash: { spy($0) })
        XCTAssertNil(try jobs.importModel(try stl(PrepTests.box(half: [8, 8, 16]), in: fx.root), name: "ogre", sizes: sizes))
        XCTAssertTrue(eventually { fm.fileExists(atPath: started) }, "print prep never started")
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["ogre"])
    }

    func testAnImportsFirstPrintPrepIsCalledImporting() throws {
        let fx = try Fixture()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        try jobs.importModel(try stl(PrepTests.box(half: [8, 8, 16]), in: fx.root), name: "ogre", sizes: sizes)
        jobs.waitUntilDone()
        let d = fx.install.runs.appendingPathComponent("ogre")
        XCTAssertEqual(jobs.status?.importing, true)
        XCTAssertTrue(JobRunner.importing(d))
        XCTAssertEqual(JobRunner.doing(.prep, importing: JobRunner.importing(d)), "Importing")
        fm.createFile(atPath: d.appendingPathComponent("ogre.stl").path, contents: Data("stl".utf8))
        XCTAssertFalse(JobRunner.importing(d), "once made, its print prep is a resize")
        try jobs.resize(name: "ogre", sizes: Sizes(height: "60", nozzle: "0.4"))
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.importing, false)
        XCTAssertEqual(JobRunner.doing(.prep, importing: false), "Resizing")
        XCTAssertEqual(JobRunner.doing(.generate, importing: false), "Making")
        XCTAssertFalse(JobRunner.importing(try fx.mini("dwarf")))
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
        XCTAssertEqual(rows, ["Source: A 3D model you imported"])
    }
}
