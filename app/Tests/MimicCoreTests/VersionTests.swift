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

    /// Several pictures dropped on New Mini: each named after its file.
    func testANameFromThePicturesFile() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("tiefling")
        let pic = { (file: String) in URL(fileURLWithPath: "/tmp/\(file)") }
        XCTAssertEqual(Gallery.name(forPicture: pic("Dwarf Cleric.png"), in: runs), "dwarf-cleric")
        XCTAssertEqual(Gallery.name(forPicture: pic("Tiefling.jpg"), in: runs), "tiefling-2", "tiefling is taken")
        XCTAssertEqual(Gallery.name(forPicture: pic("Élodie.png"), in: runs), "elodie")
        XCTAssertEqual(Gallery.name(forPicture: pic("日本.png"), in: runs), "ri-ben")
        XCTAssertEqual(Gallery.name(forPicture: pic("🐉.png"), in: runs), "mini")
    }

    /// A sibling from the same source and settings, in the same project, with a new seed that
    /// reaches both the drawing and the 3D engine.
    func testAnotherVersionCopiesTheSettingsWithANewSeed() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles(); try fx.modelFiles(EngineDownload.model("pixal3d-sv")!)
        let tools = fx.tools()
        let picture = try fx.picture()
        try Gallery.createProject(runs, "Tiefling Party")
        // Something runs first, so the versions wait and nothing is drawn.
        _ = try fx.mini("busy")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 2)))
        try jobs.resize(name: "busy", sizes: sizes)
        let big = Sizes(height: "100", base: "40", nozzle: "0.2")
        try jobs.make(name: "wizard", picture: .image(picture), restyle: false, seed: 7, sizes: big, kind: .object,
                      model: EngineDownload.model("pixal3d-sv")!, project: "Tiefling Party")
        try jobs.make(name: "sculpted", picture: .image(picture), restyle: true, seed: 7, sizes: big, model: EngineDownload.standard, project: "Tiefling Party")
        try jobs.make(name: "toon", picture: .image(picture), restyle: true, seed: 7, sizes: big, model: EngineDownload.cartoon, cartoon: true)
        try jobs.make(name: "elf", picture: .description("an elf ranger", original: "elf"), restyle: false, seed: 42, sizes: sizes,
                      model: EngineDownload.standard)

        for (name, project) in [("wizard", "Tiefling Party"), ("sculpted", "Tiefling Party"), ("toon", nil), ("elf", nil)] as [(String, String?)] {
            let old = MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, name)))
            let (new, ahead) = try jobs.makeAnotherVersion(of: name)
            XCTAssertEqual(new, "\(name)-2")
            XCTAssertNotNil(ahead, "queued behind the busy one")
            let folder = try XCTUnwrap(Gallery.folder(runs, new))
            XCTAssertEqual(Gallery.list(runs).first { $0.name == new }?.project, project, "\(new) left its project")
            let s = MiniSettings.load(folder)
            XCTAssertNotEqual(s.seed, old.seed, name)
            XCTAssertEqual(s.versionOf, name)
            XCTAssertNotNil(s.created, "a new version is a new mini, dated when it was asked for")
            var same = s; same.seed = old.seed; same.versionOf = nil; same.created = old.created
            XCTAssertEqual(same, old, "\(name): settings other than the seed changed")
            let seed = String(s.seed!)
            let plan = try Pipeline.plan(.generate, folder: folder, settings: s, tools: tools).map(\.step)
            let source = folder.appendingPathComponent("source.png"), upload = folder.appendingPathComponent("upload.img")
            switch name {
            case "wizard":  // the same picture, not redrawn: only the 3D seed changes
                XCTAssertEqual(plan[0], .copyPicture(from: upload, to: source))
                XCTAssertEqual(try Engine.rgba(Engine.load(upload)), try Engine.rgba(Engine.load(picture)))
            case "sculpted", "toon": XCTAssertEqual(plan[0], .sculptPicture(from: upload, seed: s.seed!, to: source))
            default: XCTAssertEqual(plan[0], .drawCharacter(description: "an elf ranger", seed: s.seed!, to: source))
            }
            guard case .run(_, let args, _, _) = plan[1] else { return XCTFail("step 2 isn't the engine") }
            XCTAssertEqual(args[args.firstIndex(of: "--seed")! + 1], seed, "\(name): the 3D engine gets the old seed")
        }
        XCTAssertEqual(try jobs.makeAnotherVersion(of: "wizard-2").name, "wizard-3")
        XCTAssertEqual(MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, "wizard-3"))).versionOf, "wizard", "a version of a version names the first")
        // A version keeps the name it was given, numbered (#87), where its folder's is "Elodie 2".
        try jobs.make(name: "elodie", picture: .description("an elf"), restyle: false, seed: 1, sizes: sizes,
                      model: EngineDownload.standard, shown: "Élodie")
        let elodie2 = try jobs.makeAnotherVersion(of: "elodie").name
        XCTAssertEqual(Gallery.list(runs).first { $0.name == elodie2 }?.displayName, "Élodie 2")
        for n in jobs.queue.entries().map(\.name) { try jobs.remove(n) }
        jobs.waitUntilDone()
    }

    /// A mini's versions are the first one and those naming it, in its project; renaming the
    /// first keeps them together.
    func testTheVersionsOfAMini() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("dwarf"); _ = try fx.mini("elf")
        for v in ["dwarf-2", "dwarf-3"] { try MiniSettings.update(try fx.mini(v)) { $0.versionOf = "dwarf" } }
        let names = { (m: String) in Gallery.versions(of: Gallery.list(runs).first { $0.name == m }!, in: Gallery.list(runs)).map(\.name) }
        XCTAssertEqual(names("dwarf-3"), ["dwarf", "dwarf-2", "dwarf-3"])
        XCTAssertEqual(names("elf"), ["elf"])
        try Gallery.rename(runs, from: "dwarf", to: "dwarf-king")
        XCTAssertEqual(names("dwarf-2"), ["dwarf-2", "dwarf-3", "dwarf-king"])
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

    /// Edit & Make Again (#84): New Mini filled in from a mini, then made unchanged as New Mini
    /// makes it, gives a mini whose settings are the old one's but for its name and date. So a
    /// choice the form leaves behind, or a setting added later that it doesn't carry, fails here.
    func testEditAndMakeAgainCarriesEveryChoice() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let pixal = try XCTUnwrap(EngineDownload.model("pixal3d-sv"))
        try fx.modelFiles(); try fx.modelFiles(pixal)
        let picture = try fx.picture()
        try Gallery.createProject(runs, "Tiefling Party")
        // Paused, so the minis wait and nothing runs or changes their settings.
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        try jobs.setPaused(true)
        // Every size chosen, none left to the card's suggestions.
        let full = Sizes(height: "100", base: "40", nozzle: "0.2", inflate: "0.15", shape: .hex, style: .stone, magnet: .mm6x2)
        try jobs.make(name: "elodie", picture: .image(picture), restyle: true, seed: 7, sizes: full, kind: .object,
                      model: pixal, project: "Tiefling Party", shown: "Élodie")
        try jobs.make(name: "toon", picture: .image(picture), restyle: true, seed: 123, sizes: full, model: EngineDownload.cartoon, cartoon: true)
        try jobs.make(name: "plain", picture: .image(picture), restyle: false, seed: 5, sizes: full, model: EngineDownload.standard)
        try jobs.make(name: "elf", picture: .description("an elf ranger with a bow", original: "elf archer"), restyle: false, seed: 9,
                      sizes: full, model: EngineDownload.standard, project: "Tiefling Party")
        try jobs.make(name: "dwarf", picture: .description("a dwarf"), restyle: false, seed: 42,
                      sizes: Sizes(height: "32", base: "25", nozzle: "0.4", noBase: true), model: EngineDownload.standard)

        let minis = Gallery.list(runs)
        for name in ["elodie", "toon", "plain", "elf", "dwarf"] {
            let mini = try XCTUnwrap(minis.first { $0.name == name })
            let f = try XCTUnwrap(MakeForm.again(mini, install: fx.install, card: SizeCard()), name)
            let new = Rules.folderName(f.name)
            XCTAssertEqual(new, "\(name)-2", "\(name): the name filled in gives a new version's folder")
            // What MakeView.make() does with the form's values.
            let source: PictureSource = f.fromPicture ? .image(try XCTUnwrap(f.picture))
                : f.improved.map { PictureSource.description($0, original: f.description) } ?? .description(f.description)
            let model = EngineDownload.forMaking(cartoon: f.cartoon, chosen: f.model.flatMap { EngineDownload.model($0) } ?? EngineDownload.standard)
            try jobs.make(name: new, picture: source, restyle: f.fromPicture && f.restyle, seed: f.seed, sizes: f.card.sizes,
                          kind: f.card.kind, model: model, project: f.project, cartoon: f.cartoon, shown: f.name)
            let folder = try XCTUnwrap(Gallery.folder(runs, new))
            var old = mini.settings, made = MiniSettings.load(folder)
            XCTAssertNotNil(made.created)
            old.name = nil; old.nameFolder = nil; old.created = nil
            made.name = nil; made.nameFolder = nil; made.created = nil
            XCTAssertEqual(made, old, "\(name): a choice wasn't carried over")
            XCTAssertEqual(Gallery.list(runs).first { $0.name == new }?.project, mini.project, "\(name) left its project")
            if f.fromPicture {
                XCTAssertEqual(try Engine.rgba(Engine.load(folder.appendingPathComponent("upload.img"))),
                               try Engine.rgba(Engine.load(mini.folder.appendingPathComponent("upload.img"))), "\(name): not the same picture")
            }
        }
        let form = { (name: String) in MakeForm.again(Gallery.list(runs).first { $0.name == name }!, install: fx.install, card: SizeCard())! }
        // The name as typed, numbered; the description as typed, with the helper's version shown.
        XCTAssertEqual(form("elodie").name, "Élodie 3", "elodie-2 is taken now")
        XCTAssertEqual(form("elf").description, "elf archer")
        XCTAssertEqual(form("elf").improved, "an elf ranger with a bow")
        XCTAssertEqual(form("dwarf").description, "a dwarf")
        XCTAssertNil(form("dwarf").improved)
        XCTAssertEqual(form("dwarf").name, "Dwarf 3")
        XCTAssertEqual(form("plain").restyle, false)
        XCTAssertEqual(form("elodie").model, "pixal3d-sv", "made with Pixal3D, not this Mac's choice")
        XCTAssertNil(form("toon").model, "a cartoon is always made with Pixal3D")
        for n in jobs.queue.entries().map(\.name) { try jobs.remove(n) }
        jobs.waitUntilDone()
    }

    /// Older minis: one from before upload.img was kept is filled in with source.png, without
    /// the sculpt it already is; one with nothing saved to make it from can't be; a model that
    /// isn't here any more is this Mac's choice instead.
    func testEditAndMakeAgainOfOlderMinis() throws {
        let fx = try Fixture()
        let old = try fx.mini("old-picture")
        try MiniSettings.update(old) {
            $0.source = .image; $0.restyle = true; $0.requested = self.sizes; $0.model = "pixal3d-sv"; $0.seed = 3
        }
        _ = try fx.mini("tiefling-sculpt")  // model.glb and no settings.json
        let minis = Gallery.list(fx.install.runs)
        let f = try XCTUnwrap(MakeForm.again(minis.first { $0.name == "old-picture" }!, install: fx.install, card: SizeCard()))
        XCTAssertEqual(f.picture?.lastPathComponent, "source.png")
        XCTAssertTrue(f.fromPicture)
        XCTAssertFalse(f.restyle, "source.png is already the sculpt")
        XCTAssertEqual(f.seed, 3)
        XCTAssertEqual(f.card.sizes, SizeCard().loaded(sizes))
        XCTAssertNil(f.model, "Pixal3D isn't downloaded")
        XCTAssertEqual(f.name, "Old Picture 2")
        XCTAssertNil(MakeForm.again(minis.first { $0.name == "tiefling-sculpt" }!, install: fx.install, card: SizeCard()))
    }
}

private extension SizeCard {
    func loaded(_ s: Sizes) -> Sizes { var c = self; c.load(s); return c.sizes }
}
