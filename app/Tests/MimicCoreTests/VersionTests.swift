import XCTest
@testable import MimicCore

/// Make Another Version.
final class VersionTests: XCTestCase {
    let sizes = Sizes(height: "32", nozzle: "0.4")
    let fm = FileManager.default

    func testTheNextVersionName() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("tiefling-wizard-version-7")
        _ = try fx.mini("raven")
        _ = try fx.mini("raven-2", in: "Birds")
        XCTAssertEqual(Gallery.nextVersionName(runs, "tiefling-wizard-version-7"), "tiefling-wizard-version-8")
        XCTAssertEqual(Gallery.nextVersionName(runs, "raven"), "raven-3", "raven-2 is taken, in another project")
        XCTAssertEqual(Gallery.nextVersionName(runs, "raven-2"), "raven-3")
        XCTAssertEqual(Gallery.nextVersionName(runs, "orc-2024"), "orc-2024-2", "a year isn't a version number")
        let long = String(repeating: "a", count: 64)
        XCTAssertEqual(Gallery.nextVersionName(runs, long).count, 64)
    }

    /// A sibling from the same source and settings, in the same project, with a new seed that
    /// reaches both the drawing and the 3D engine.
    func testAnotherVersionCopiesTheSettingsWithANewSeed() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles(); try fx.modelFiles(EngineDownload.model("trellis2-q4")!)
        let tools = fx.tools()
        let picture = fx.root.appendingPathComponent("pic.png"); fm.createFile(atPath: picture.path, contents: Data("the picture".utf8))
        try Gallery.createProject(runs, "Tiefling Party")
        // Something runs first, so the versions wait and nothing is drawn.
        _ = try fx.mini("busy")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 2)))
        try jobs.resize(name: "busy", sizes: sizes)
        let big = Sizes(height: "100", base: "40", nozzle: "0.2")
        try jobs.make(name: "wizard", picture: .image(picture), restyle: false, seed: 7, sizes: big, kind: .object,
                      model: EngineDownload.model("trellis2-q4")!, project: "Tiefling Party")
        try jobs.make(name: "sculpted", picture: .image(picture), restyle: true, seed: 7, sizes: big, model: EngineDownload.standard, project: "Tiefling Party")
        try jobs.make(name: "elf", picture: .description("an elf ranger", original: "elf"), restyle: false, seed: 42, sizes: sizes,
                      model: EngineDownload.standard)

        for (name, project) in [("wizard", "Tiefling Party"), ("sculpted", "Tiefling Party"), ("elf", nil)] as [(String, String?)] {
            let old = MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, name)))
            let (new, ahead) = try jobs.makeAnotherVersion(of: name)
            XCTAssertEqual(new, "\(name)-2")
            XCTAssertNotNil(ahead, "queued behind the busy one")
            let folder = try XCTUnwrap(Gallery.folder(runs, new))
            XCTAssertEqual(Gallery.list(runs).first { $0.name == new }?.project, project, "\(new) left its project")
            let s = MiniSettings.load(folder)
            XCTAssertNotEqual(s.seed, old.seed, name)
            var same = s; same.seed = old.seed
            XCTAssertEqual(same, old, "\(name): settings other than the seed changed")
            let seed = String(s.seed!)
            let plan = try Pipeline.plan(.generate, folder: folder, settings: s, tools: tools).map(\.step)
            let source = folder.appendingPathComponent("source.png"), upload = folder.appendingPathComponent("upload.img")
            switch name {
            case "wizard":  // the same picture, not redrawn: only the 3D seed changes
                XCTAssertEqual(plan[0], .copyPicture(from: upload, to: source))
                XCTAssertEqual(try Data(contentsOf: upload), Data("the picture".utf8))
            case "sculpted": XCTAssertEqual(plan[0], .sculptPicture(from: upload, seed: s.seed!, to: source))
            default: XCTAssertEqual(plan[0], .drawCharacter(description: "an elf ranger", seed: s.seed!, to: source))
            }
            guard case .run(_, let args, _, _) = plan[1] else { return XCTFail("step 2 isn't the engine") }
            XCTAssertEqual(args[args.firstIndex(of: "--seed")! + 1], seed, "\(name): the 3D engine gets the old seed")
        }
        XCTAssertEqual(try jobs.makeAnotherVersion(of: "wizard").name, "wizard-3")
        for n in jobs.queue.entries().map(\.name) { try jobs.remove(n) }
        jobs.waitUntilDone()
    }

    /// Older minis: a picture mini from before upload.img was kept uses source.png as it is; one
    /// with no settings at all can't be made again.
    func testAnotherVersionOfOlderMinis() throws {
        let fx = try Fixture()
        try fx.modelFiles()
        let old = try fx.mini("old-picture")
        try MiniSettings.update(old) { $0.source = .image; $0.restyle = true; $0.requested = self.sizes }
        _ = try fx.mini("tiefling-sculpt")  // model.glb and no settings.json
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        let (picture, restyle, _) = try JobRunner.versionSource(old)
        guard case .image(let url) = picture else { return XCTFail() }
        XCTAssertEqual(url.lastPathComponent, "source.png")
        XCTAssertFalse(restyle, "source.png is already the sculpt")
        XCTAssertFalse(JobRunner.canMakeAnotherVersion(Gallery.list(fx.install.runs).first { $0.name == "tiefling-sculpt" }!))
        XCTAssertThrowsError(try jobs.makeAnotherVersion(of: "tiefling-sculpt")) { XCTAssertEqual($0 as? RequestError, .noSource("tiefling-sculpt")) }
    }
}
