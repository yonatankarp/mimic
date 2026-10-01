import XCTest
@testable import MimicCore

/// What to change in a picture, said in words (#156): the redraw makes the fix, and fixes add
/// up from version to version.
final class FixTests: XCTestCase {
    let sizes = Sizes(height: "32")
    let fm = FileManager.default

    /// The fix comes before what the redraw keeps, as the one change; without one, the redraw
    /// is word for word today's.
    func testTheRedrawIsToldTheFix() {
        for kind in [MiniKind.character, .object] {
            let plain = DrawThings.redrawPrompt(kind: kind)
            XCTAssertEqual(plain, kind == .object ? DrawThings.objectSculptPrompt : DrawThings.sculptPrompt)
            XCTAssertEqual(DrawThings.redrawPrompt(kind: kind, change: "  \n"), plain, "an empty box is no fix")
            let fixed = DrawThings.redrawPrompt(kind: kind, change: " shorter sword, held against the chest ")
            XCTAssertTrue(fixed.contains(" Make this one change: shorter sword, held against the chest. Apart from that change, keep the same "), fixed)
            XCTAssertEqual(fixed.components(separatedBy: "Keep the same").count, 1, "the keep list is said once, after the fix")
            XCTAssertTrue(fixed.hasPrefix(plain.components(separatedBy: " Keep the same").first!), fixed)
        }
        XCTAssertTrue(DrawThings.redrawPrompt(kind: .character, change: "Close the cape.").contains("change: Close the cape. Apart"), "no second full stop")
    }

    /// A fix is saved with the mini, as typed and as the helper rewrote it, and turns the redraw
    /// on; Try Again redraws with the same fix.
    func testAFixIsSavedAndTurnsTheRedrawOn() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let picture = try fx.picture()
        let jobs = try busy(fx)
        try jobs.make(name: "dwarf", picture: .image(picture), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      fixes: ["  shorter sword ", ""], fixUsed: "Make the sword half as long, held against the chest.")
        let d = try XCTUnwrap(Gallery.folder(fx.install.runs, "dwarf"))
        let s = MiniSettings.load(d)
        XCTAssertEqual(s.fixes, ["shorter sword"])
        XCTAssertEqual(s.fixUsed, "Make the sword half as long, held against the chest.")
        XCTAssertEqual(s.restyle, true, "a fix is made by the redraw")
        let plan = try Pipeline.plan(.generate, folder: d, settings: s, tools: fx.tools())
        XCTAssertEqual(plan[0].step, .sculptPicture(from: d.appendingPathComponent("upload.img"), seed: 7, to: d.appendingPathComponent("source.png"),
                                                    change: "Make the sword half as long, held against the chest."))

        // As typed when the helper wasn't asked, or gave it back the same.
        try jobs.make(name: "elf", picture: .image(picture), restyle: true, seed: 7, sizes: sizes, kind: .object, model: EngineDownload.standard,
                      fixes: ["remove the stand"], fixUsed: "remove the stand")
        let e = try XCTUnwrap(Gallery.folder(fx.install.runs, "elf"))
        XCTAssertNil(MiniSettings.load(e).fixUsed)
        XCTAssertEqual(try Pipeline.plan(.generate, folder: e, settings: MiniSettings.load(e), tools: fx.tools())[0].step,
                       .sculptObject(from: e.appendingPathComponent("upload.img"), seed: 7, to: e.appendingPathComponent("source.png"), change: "remove the stand"))

        // No fix: today's mini, with nothing saved for one.
        try jobs.make(name: "plain", picture: .image(picture), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard, fixes: [" "])
        let p = MiniSettings.load(try XCTUnwrap(Gallery.folder(fx.install.runs, "plain")))
        XCTAssertNil(p.fixes); XCTAssertNil(p.fixUsed); XCTAssertEqual(p.restyle, false)

        // A description is changed by changing it.
        XCTAssertThrowsError(try jobs.make(name: "orc", picture: .description("an orc"), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard, fixes: ["bigger axe"])) {
            XCTAssertEqual($0 as? RequestError, .fixNeedsAPicture)
        }
        XCTAssertNil(Gallery.folder(fx.install.runs, "orc"), "a refused mini left a folder")
        try clear(jobs)
    }

    /// Make Another Version with a fix starts from the picture this version's step 1 made, and
    /// adds its fix to this one's; without one it's made as before, from the same upload and fix.
    func testFixesAddUpFromVersionToVersion() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let picture = try fx.picture(), other = try fx.picture("drawn.png")
        try Engine.writePNG([UInt8](repeating: 90, count: 8 * 8 * 4), width: 8, height: 8, to: other)
        let jobs = try busy(fx), runs = fx.install.runs
        try jobs.make(name: "knight", picture: .image(picture), restyle: true, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      fixes: ["close the cape"])
        let knight = try XCTUnwrap(Gallery.folder(runs, "knight"))
        XCTAssertThrowsError(try jobs.makeAnotherVersion(of: "knight", change: "thicker staff")) {
            XCTAssertEqual($0 as? RequestError, .noPictureToFix("knight"), "no picture made yet to change")
        }
        try fm.copyItem(at: other, to: knight.appendingPathComponent("source.png"))  // step 1 made it

        let fixed = try jobs.makeAnotherVersion(of: "knight", change: " thicker staff ", changeUsed: "Make the staff twice as thick.").name
        let f = try XCTUnwrap(Gallery.folder(runs, fixed))
        let s = MiniSettings.load(f)
        XCTAssertEqual(s.fixes, ["close the cape", "thicker staff"])
        XCTAssertEqual(s.fixUsed, "Make the staff twice as thick.")
        XCTAssertEqual(s.versionOf, "knight")
        XCTAssertEqual(try Engine.rgba(Engine.load(f.appendingPathComponent("upload.img"))), try Engine.rgba(Engine.load(other)),
                       "starts from the picture the knight's step 1 made")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: f, settings: s, tools: fx.tools())[0].step,
                       .sculptPicture(from: f.appendingPathComponent("upload.img"), seed: s.seed!, to: f.appendingPathComponent("source.png"),
                                      change: "Make the staff twice as thick."), "only the new fix: the picture has the earlier one")

        let same = MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, try jobs.makeAnotherVersion(of: "knight").name)))
        XCTAssertEqual(same.fixes, ["close the cape"], "no new fix keeps the one it had")
        let sameFolder = try XCTUnwrap(Gallery.folder(runs, "knight-3"))
        XCTAssertEqual(try Engine.rgba(Engine.load(sameFolder.appendingPathComponent("upload.img"))), try Engine.rgba(Engine.load(picture)))

        // New 3D Shape with a fix redraws the picture it had, keeping its number; without one
        // it keeps the picture as it is.
        let shaped = try jobs.makeNewShape(of: "knight", change: "no helmet").name
        let n = try XCTUnwrap(Gallery.folder(runs, shaped))
        let ns = MiniSettings.load(n)
        XCTAssertEqual(ns.fixes, ["close the cape", "no helmet"])
        XCTAssertEqual(ns.seed, 7)
        XCTAssertNotNil(ns.shapeSeed)
        XCTAssertFalse(fm.fileExists(atPath: n.appendingPathComponent("source.png").path), "redrawn, not copied")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: n, settings: ns, tools: fx.tools()).map(\.number), [.picture, .shape, .print])
        let kept = try XCTUnwrap(Gallery.folder(runs, try jobs.makeNewShape(of: "knight").name))
        XCTAssertTrue(fm.fileExists(atPath: kept.appendingPathComponent("source.png").path), "an empty box is the same picture")
        try clear(jobs)
    }

    /// A version made with a change stops for its picture to be checked when asked; one without
    /// a new picture to check (New 3D Shape keeping its picture) never does.
    func testAVersionWithAChangeStopsForItsPicture() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let jobs = try busy(fx), runs = fx.install.runs
        try jobs.make(name: "knight", picture: .image(try fx.picture()), restyle: true, seed: 7, sizes: sizes, model: EngineDownload.standard)
        let knight = try XCTUnwrap(Gallery.folder(runs, "knight"))
        try fm.copyItem(at: try fx.picture(), to: knight.appendingPathComponent("source.png"))
        let checked = try jobs.makeAnotherVersion(of: "knight", change: "no helmet", checkPicture: true).name
        XCTAssertEqual(MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, checked))).checkPicture, true)
        XCTAssertNil(MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, try jobs.makeAnotherVersion(of: "knight").name))).checkPicture)
        XCTAssertNil(MiniSettings.load(try XCTUnwrap(Gallery.folder(runs, try jobs.makeNewShape(of: "knight", checkPicture: true).name))).checkPicture,
                     "its picture is copied, so there's nothing to check")
        try clear(jobs)
    }

    /// Edit & Make Again is filled in with the fixes a mini had, and the pictures its step 1
    /// made, which a new change starts from.
    func testEditAndMakeAgainKnowsTheFixes() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let jobs = try busy(fx), runs = fx.install.runs
        try jobs.make(name: "knight", picture: .image(try fx.picture()), restyle: true, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      fixes: ["close the cape"], fixUsed: "Close the cape at the front.")
        let mini = { Gallery.list(runs).first { $0.name == "knight" }! }
        var form = try XCTUnwrap(MakeForm.again(mini(), install: fx.install, card: SizeCard()))
        XCTAssertEqual(form.fixes, ["close the cape"])
        XCTAssertEqual(form.fixUsed, "Close the cape at the front.")
        XCTAssertNil(form.drawn, "no picture made yet")
        let knight = try XCTUnwrap(Gallery.folder(runs, "knight"))
        try fm.copyItem(at: try fx.picture(), to: knight.appendingPathComponent("source.png"))
        form = try XCTUnwrap(MakeForm.again(mini(), install: fx.install, card: SizeCard()))
        XCTAssertEqual(form.drawn?.lastPathComponent, "source.png")
        XCTAssertEqual(form.picture?.lastPathComponent, "upload.img", "without a change it's made from the same picture as before")
        try clear(jobs)
    }

    /// A description mini changed with a fix becomes one made from its picture.
    func testAFixOnADescriptionMiniStartsFromItsPicture() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let jobs = try busy(fx), runs = fx.install.runs
        try jobs.make(name: "elf", picture: .description("an elf ranger"), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard)
        let elf = try XCTUnwrap(Gallery.folder(runs, "elf"))
        try fm.copyItem(at: try fx.picture(), to: elf.appendingPathComponent("source.png"))
        let v = try XCTUnwrap(Gallery.folder(runs, try jobs.makeAnotherVersion(of: "elf", change: "a longer bow").name))
        let s = MiniSettings.load(v)
        XCTAssertEqual(s.source, .image)
        XCTAssertEqual(s.restyle, true)
        XCTAssertEqual(s.fixes, ["a longer bow"])
        try clear(jobs)
    }

    /// Its fixes are listed under Made From, and by `mimic info`, as typed.
    func testMadeFromListsTheFixes() throws {
        var s = MiniSettings()
        s.source = .image; s.restyle = true; s.fixes = ["close the cape", "thicker staff"]; s.fixUsed = "Make the staff twice as thick."
        XCTAssertEqual(MadeFrom(s, created: .distantPast).fixes, ["close the cape", "thicker staff"])
        XCTAssertEqual(MadeFrom(MiniSettings(), created: .distantPast).fixes, [])
        let fx = try Fixture()
        let d = try fx.mini("knight")
        try MiniSettings.update(d) { $0.fixes = s.fixes }
        let mini = try XCTUnwrap(Gallery.list(fx.install.runs).first)
        let lines = MiniInfo(mini, in: [mini], waiting: []).lines
        XCTAssertTrue(lines.contains("Changed: close the cape") && lines.contains("Changed: thicker staff"), "\(lines)")
    }

    /// The helper's rewrite is kept as it wrote it: unlike a description, its first word isn't
    /// an article to drop, and nothing in it is a phrase list to trim.
    func testTheHelpersFixIsTidiedNotCut() {
        XCTAssertEqual(DescriptionHelper.tidy("<think>hm</think>\n\"The cape closes at the front,\n so both arms show.\""),
                       "The cape closes at the front, so both arms show.")
        XCTAssertTrue(DescriptionHelper.fixPrompt(kind: "object").contains("a picture of an object"))
        XCTAssertTrue(DescriptionHelper.fixPrompt().contains("a picture of a character"))
    }

    // MARK: Helpers

    /// A runner busy resizing, so the minis these tests make wait and nothing is drawn.
    private func busy(_ fx: Fixture) throws -> JobRunner {
        _ = try fx.mini("busy")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 2)))
        try jobs.resize(name: "busy", sizes: sizes)
        return jobs
    }

    private func clear(_ jobs: JobRunner) throws {
        for n in jobs.queue.entries().map(\.name) { try jobs.remove(n) }
        jobs.waitUntilDone()
    }
}
