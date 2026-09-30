import XCTest
@testable import MimicCore

/// Duplicate (#85): a copy of a made mini under a new name, to resize without losing the first.
final class DuplicateTests: XCTestCase {
    let sizes = Sizes(height: "32", nozzle: "0.4")
    let fm = FileManager.default

    func files(_ d: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: d.path).sorted() }

    /// A made raven, a version of another, with the logs of how it was made and a print file
    /// prep left half written.
    func raven(_ fx: Fixture, in project: String? = nil) throws -> URL {
        let d = try project.map { try fx.mini("raven", in: $0) } ?? fx.mini("raven")
        for f in ["generate.job.log", "prep.job.log", "pixal3d.log", "prep.log", "raven.part.stl", "upload.img"] {
            fm.createFile(atPath: d.appendingPathComponent(f).path, contents: Data(f.utf8))
        }
        try MiniSettings.update(d) { s in
            s.name("Raven the Bold", folder: "raven")
            s.versionOf = "tiefling-raven"; s.seed = 7; s.requested = sizes; s.made = sizes
            s.created = Date(timeIntervalSince1970: 1_600_000_000)
        }
        return d
    }

    func testACopyHasTheShapeAndPicturesButNotTheLogs() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let d = try raven(fx)
        let before = try files(d)
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        try jobs.duplicate("raven", as: "raven-display", shown: "Raven Display")

        let copy = runs.appendingPathComponent("raven-display")
        XCTAssertEqual(try files(copy), ["model.glb", "raven-display.stl", "raven-display_back.png", "raven-display_front.png",
                                         "raven-display_left.png", "raven-display_right.png", "settings.json", "source.png", "upload.img"])
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("model.glb")), Data("model.glb".utf8))
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("raven-display.stl")), Data("raven.stl".utf8))
        XCTAssertEqual(try files(d), before, "the original changed")
        XCTAssertEqual(try Data(contentsOf: d.appendingPathComponent("raven.stl")), Data("raven.stl".utf8))
        XCTAssertEqual(try files(runs).filter { !$0.hasPrefix(".") }, ["raven", "raven-display"], "a half-made copy was left behind")

        let minis = Gallery.list(runs)
        let original = try XCTUnwrap(minis.first { $0.name == "raven" }), dup = try XCTUnwrap(minis.first { $0.name == "raven-display" })
        XCTAssertEqual(dup.displayName, "Raven Display")
        XCTAssertEqual(original.displayName, "Raven the Bold")
        XCTAssertEqual(dup.settings.seed, 7)
        XCTAssertEqual(dup.settings.made, sizes, "Resize starts from the sizes it was made at")
        XCTAssertNil(dup.settings.versionOf, "a copy is not another version: Keep This One would trash it")
        XCTAssertEqual(original.settings.versionOf, "tiefling-raven")
        XCTAssertGreaterThan(dup.created, original.created, "a copy is asked for now")
        XCTAssertEqual(dup.stl?.path, copy.appendingPathComponent("raven-display.stl").path)
        XCTAssertEqual(Gallery.adopt(runs, busy: []), [], "taken over as if it were copied in Finder")
        try jobs.resize(name: "raven-display", sizes: Sizes(height: "100", nozzle: "0.4"))
        jobs.waitUntilDone()
    }

    func testACopyStaysInItsProject() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try raven(fx, in: "Tiefling Party")
        try JobRunner(install: fx.install, tools: fx.tools()).duplicate("raven", as: "raven-2", shown: "Raven 2")
        XCTAssertEqual(Gallery.folder(runs, "raven-2")?.path, runs.appendingPathComponent("Tiefling Party/raven-2").path)
        XCTAssertEqual(Gallery.list(runs).first { $0.name == "raven-2" }?.project, "Tiefling Party")
        XCTAssertEqual(try files(runs.appendingPathComponent("Tiefling Party")), ["raven", "raven-2"])
    }

    func testDuplicateIsRefusedWhileBusyWithoutAShapeOrUnderATakenName() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try raven(fx)
        _ = try fx.mini("elf")
        try Gallery.createProject(runs, "Orcs")
        let unmade = runs.appendingPathComponent("dwarf")
        try fm.createDirectory(at: unmade, withIntermediateDirectories: true)
        try MiniSettings.update(unmade) { $0.source = .desc; $0.desc = "a dwarf" }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "sleep 1")))

        XCTAssertThrowsError(try jobs.duplicate("nobody", as: "x")) { XCTAssertEqual($0 as? RequestError, .notFound) }
        XCTAssertThrowsError(try jobs.duplicate("dwarf", as: "dwarf-2")) { XCTAssertEqual($0 as? RequestError, .noModelYet) }
        XCTAssertThrowsError(try jobs.duplicate("raven", as: "elf")) { XCTAssertEqual($0 as? RequestError, .nameTaken("elf")) }
        XCTAssertThrowsError(try jobs.duplicate("raven", as: "orcs")) { XCTAssertEqual($0 as? RequestError, .nameTaken("orcs")) }
        XCTAssertThrowsError(try jobs.duplicate("raven", as: "Raven 2")) { XCTAssertEqual($0 as? RequestError, .badName) }

        try jobs.resize(name: "raven", sizes: sizes)
        try jobs.resize(name: "elf", sizes: sizes)
        for n in ["raven", "elf"] {  // being resized, and waiting
            XCTAssertThrowsError(try jobs.duplicate(n, as: "\(n)-copy")) { XCTAssertEqual($0 as? RequestError, .cantDuplicate(n)) }
        }
        jobs.waitUntilDone()
        XCTAssertEqual(try files(runs).filter { !$0.hasPrefix(".") }, ["Orcs", "dwarf", "elf", "raven"])
        try jobs.duplicate("elf", as: "elf-copy")
        XCTAssertEqual(Gallery.list(runs).first { $0.name == "elf-copy" }?.displayName, "Elf Copy")
    }

    /// Offered as the next number, as a new version or a second picture of the same name is.
    func testTheNameOfferedIsTheNextNumber() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try raven(fx)
        _ = try fx.mini("elf")
        let bard = try fx.mini("d-d-bard")
        try MiniSettings.update(bard) { $0.name("D&D Bard", folder: "d-d-bard") }
        func offered(_ name: String) throws -> (String, String) {
            let m = try XCTUnwrap(Gallery.list(runs).first { $0.name == name })
            let n = Gallery.duplicateName(runs, m)
            return (n.shown, n.folder)
        }
        // Its folder "raven-the-bold" is free, but it would show as the same name as the first.
        XCTAssertEqual(try offered("raven").0, "Raven the Bold 2")
        XCTAssertEqual(try offered("raven").1, "raven-the-bold-2")
        XCTAssertEqual(try offered("elf").0, "Elf 2")
        XCTAssertEqual(try offered("elf").1, "elf-2")
        XCTAssertEqual(try offered("d-d-bard").0, "D&D Bard 2")
        XCTAssertEqual(try offered("d-d-bard").1, "d-d-bard-2")
        _ = try fx.mini("d-d-bard-2")
        XCTAssertEqual(try offered("d-d-bard").1, "d-d-bard-3")
        XCTAssertEqual(try offered("d-d-bard").0, "D&D Bard 3")
    }
}
