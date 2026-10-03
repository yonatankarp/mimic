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

    /// A typed name's folder, or the next one free: taken by a mini at the top, by one in a
    /// project, or by a project itself, in any case.
    func testAFreeName() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("tiefling")
        _ = try fx.mini("tiefling-2", in: "Party")
        _ = try fx.mini("mini")
        XCTAssertEqual(Gallery.freeName(runs, "Dwarf Cleric"), "dwarf-cleric")
        XCTAssertEqual(Gallery.freeName(runs, "Tiefling"), "tiefling-3", "tiefling-2 is taken, in a project")
        XCTAssertEqual(Gallery.freeName(runs, "Tiefling 2"), "tiefling-3")
        XCTAssertEqual(Gallery.freeName(runs, "party"), "party-2", "a project's name is taken too")
        XCTAssertEqual(Gallery.freeName(runs, "PARTY"), "party-2")
        XCTAssertEqual(Gallery.freeName(runs, "🐉"), "mini-2", "mini is taken")
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

    /// New 3D Shape: a sibling from the picture already made, not made again, with a new seed
    /// for the 3D engine alone, saved so Try Again makes the same shape.
    func testANewShapeKeepsThePictureAndChangesOnlyTheShapesSeed() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles()
        let tools = fx.tools()
        _ = try fx.mini("busy")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 2)))
        try jobs.resize(name: "busy", sizes: sizes)
        try Gallery.createProject(runs, "Tiefling Party")
        try jobs.make(name: "elf", picture: .description("an elf ranger"), restyle: false, seed: 7, sizes: sizes,
                      model: EngineDownload.standard, project: "Tiefling Party")
        let elf = try XCTUnwrap(Gallery.folder(runs, "elf"))
        let mini = { (name: String) in Gallery.list(runs).first { $0.name == name }! }
        XCTAssertFalse(JobRunner.canMakeNewShape(mini("elf")), "no picture yet: nothing to keep")
        XCTAssertThrowsError(try jobs.makeNewShape(of: "elf")) { XCTAssertEqual($0 as? RequestError, .noDrawing("elf")) }
        XCTAssertNil(Gallery.folder(runs, "elf-2"))

        // The picture step 1 drew, as it would be once the elf is made.
        let drawing = Data("the elf as drawn".utf8)
        try drawing.write(to: elf.appendingPathComponent("source.png"))
        XCTAssertTrue(JobRunner.canMakeNewShape(mini("elf")))
        let (new, ahead) = try jobs.makeNewShape(of: "elf")
        XCTAssertEqual(new, "elf-2", "named like another version")
        XCTAssertNotNil(ahead, "queued behind the busy one")
        let folder = try XCTUnwrap(Gallery.folder(runs, new))
        XCTAssertEqual(mini(new).project, "Tiefling Party")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("source.png")), drawing, "the same picture, copied")
        let s = MiniSettings.load(folder)
        XCTAssertEqual(s.seed, 7, "the picture's own seed stays")
        let shape = try XCTUnwrap(s.shapeSeed)
        XCTAssertNotEqual(shape, 7)
        XCTAssertEqual(s.versionOf, "elf")
        // What the job (and Try Again) runs, from the new mini's settings: no drawing, the new seed.
        let plan = try Pipeline.plan(.generate, folder: folder, settings: s, tools: tools)
        XCTAssertEqual(plan.map(\.number), [.shape, .print], "the picture isn't drawn again")
        guard case .run(_, let args, _, _) = plan[0].step else { return XCTFail("step 2 isn't the engine") }
        XCTAssertEqual(args[args.firstIndex(of: "--seed")! + 1], String(shape))
        // Gone, the picture is drawn again from the same seed; the shape keeps its own.
        try fm.removeItem(at: folder.appendingPathComponent("source.png"))
        let again = try Pipeline.plan(.generate, folder: folder, settings: s, tools: tools)
        XCTAssertEqual(again[0].step, .drawCharacter(description: "an elf ranger", seed: 7, to: folder.appendingPathComponent("source.png")))
        guard case .run(_, let args2, _, _) = again[1].step else { return XCTFail("step 2 isn't the engine") }
        XCTAssertEqual(args2[args2.firstIndex(of: "--seed")! + 1], String(shape))

        XCTAssertEqual(try jobs.makeNewShape(of: "elf", seed: 99).name, "elf-3")
        XCTAssertEqual(MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, "elf-3"))).shapeSeed, 99)
        // Another version of it draws afresh: one new seed for both again.
        let other = MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, try jobs.makeAnotherVersion(of: "elf-2").name)))
        XCTAssertNil(other.shapeSeed)
        XCTAssertNotEqual(other.seed, 7)
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
        try jobs.make(name: "plain", picture: .image(picture), restyle: false, seed: 5, sizes: full, model: EngineDownload.standard, shapeSeed: 77)
        try jobs.make(name: "turnaround", picture: .image(picture), restyle: true, seed: 3, sizes: full, model: EngineDownload.standard,
                      sides: [.back: picture, .right: picture])
        try jobs.make(name: "elf", picture: .description("an elf ranger with a bow", original: "elf archer"), restyle: false, seed: 9,
                      sizes: full, model: EngineDownload.standard, project: "Tiefling Party")
        try jobs.make(name: "dwarf", picture: .description("a dwarf"), restyle: false, seed: 42,
                      sizes: Sizes(height: "32", base: "25", nozzle: "0.4", noBase: true, realHeight: "1.8"), model: EngineDownload.standard)

        let minis = Gallery.list(runs)
        for name in ["elodie", "toon", "plain", "turnaround", "elf", "dwarf"] {
            let mini = try XCTUnwrap(minis.first { $0.name == name })
            let f = try XCTUnwrap(MakeForm.again(mini, install: fx.install, card: SizeCard()), name)
            let new = Rules.folderName(f.name)
            XCTAssertEqual(new, "\(name)-2", "\(name): the name filled in gives a new version's folder")
            // What MakeView.make() does with the form's values.
            let source: PictureSource = f.fromPicture ? .image(try XCTUnwrap(f.picture))
                : f.improved.map { PictureSource.description($0, original: f.description) } ?? .description(f.description)
            let model = EngineDownload.forMaking(cartoon: f.cartoon, chosen: f.model.flatMap { EngineDownload.model($0) } ?? EngineDownload.standard)
            try jobs.make(name: new, picture: source, restyle: f.fromPicture && f.restyle, seed: f.seed, sizes: f.card.sizes,
                          kind: f.card.kind, model: model, project: f.project, cartoon: f.cartoon, shown: f.name, shapeSeed: f.shapeSeed,
                          sides: f.sides)
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

    /// #139: a mini made in Terminal without sizes records none, so print prep made it at its own
    /// defaults, and its row says "32 mm · 0.4 mm nozzle". Edit & Make Again starts there, not
    /// at the size card last chosen (here Best print, 100 mm on a 40 mm base). A size that was
    /// recorded is kept, and the rest are print prep's.
    func testEditAndMakeAgainOfAMiniWithNoRecordedSizes() throws {
        let fx = try Fixture()
        let wizard = try fx.mini("cartoon-wizard")
        try Data(#"{"source": "image", "seed": 42, "requested": {}, "made": {}}"#.utf8).write(to: wizard.appendingPathComponent("settings.json"))
        let elf = try fx.mini("elf")
        try MiniSettings.update(elf) { $0.source = .image; $0.requested = Sizes(nozzle: "0.2"); $0.made = $0.requested }
        let bestPrint = SizeCard(purpose: .display, nozzle: "0.4")
        XCTAssertEqual(bestPrint.sizes.height, "100", "the card last chosen is Best print")
        let minis = Gallery.list(fx.install.runs)
        let mini = try XCTUnwrap(minis.first { $0.name == "cartoon-wizard" })
        let f = try XCTUnwrap(MakeForm.again(mini, install: fx.install, card: bestPrint))
        XCTAssertEqual(f.card.sizes, Sizes(height: "32", base: "25", nozzle: "0.4", realHeight: "1.8"))
        XCTAssertEqual(PrintTips.shortLine(f.card.sizes), PrintTips.shortLine(try XCTUnwrap(mini.settings.made)), "the form says what the row says")
        let e = try XCTUnwrap(MakeForm.again(minis.first { $0.name == "elf" }!, install: fx.install, card: bestPrint))
        XCTAssertEqual(e.card.sizes, Sizes(height: "32", base: "25", nozzle: "0.2", realHeight: "1.8"))
        // Resize fills its card the same way; a base that wasn't made is left to the card.
        XCTAssertEqual(Sizes().asMade, Sizes(height: "32", base: "25", nozzle: "0.4"))
        XCTAssertEqual(Sizes(height: "70", noBase: true).asMade, Sizes(height: "70", nozzle: "0.4", noBase: true))
    }
}

private extension SizeCard {
    func loaded(_ s: Sizes) -> Sizes { var c = self; c.load(s); return c.sizes }
}
