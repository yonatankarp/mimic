import XCTest
@testable import MimicCore

/// The Made From section of a mini's page (#83).
final class MadeFromTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let made = Date(timeIntervalSince1970: 1_790_000_000)  // 21 Sep 2026, 14:13 UTC

    private func rows(_ m: MadeFrom) -> [String] { m.rows.map { "\($0.label): \($0.value)" } }

    func testAPictureMini() {
        var s = MiniSettings()
        s.source = .image; s.restyle = true; s.seed = 7; s.model = "trellis2-q8"; s.requested = Sizes(); s.cartoon = true
        let m = MadeFrom(s, created: made, now: made, timeZone: utc)
        XCTAssertEqual(rows(m), ["Source: A picture", "Variation number: 7", "3D model: TRELLIS.2", "Grey sculpt: On",
                                 "Cartoon: Yes", "Made: 21 Sep, 14:13"])
        XCTAssertNil(m.description, "nothing to copy for a picture")
        s.restyle = false; s.cartoon = nil
        XCTAssertTrue(rows(MadeFrom(s, created: made, now: made, timeZone: utc)).contains("Grey sculpt: Off"))
        XCTAssertFalse(rows(MadeFrom(s, created: made, now: made, timeZone: utc)).contains { $0.hasPrefix("Cartoon") })
    }

    /// Its text to copy, what was typed when the helper improved it, and no grey sculpt: a
    /// description is drawn, never sculpted, though its settings say restyle false.
    func testADescriptionMini() {
        var s = MiniSettings()
        s.source = .desc; s.desc = "an elf ranger with a longbow"; s.descOriginal = "elf ranger"; s.restyle = false; s.seed = 42
        s.model = "pixal3d-sv"; s.requested = Sizes()
        let m = MadeFrom(s, created: made, now: made, timeZone: utc)
        XCTAssertEqual(m.description, "an elf ranger with a longbow")
        XCTAssertEqual(rows(m), ["Source: A description", "You typed: elf ranger", "Variation number: 42", "3D model: Pixal3D",
                                 "Made: 21 Sep, 14:13"])
        s.descOriginal = nil
        XCTAssertFalse(rows(MadeFrom(s, created: made, now: made, timeZone: utc)).contains { $0.hasPrefix("You typed") })
    }

    /// New 3D Shape keeps `seed` and changes only `shapeSeed` (#141): the two versions' Made
    /// From must differ, and a mini without its own shape number has no row for one.
    func testANewShapeShowsItsShapeNumber() {
        var s = MiniSettings()
        s.source = .image; s.seed = 42; s.requested = Sizes()
        let first = rows(MadeFrom(s, created: made, now: made, timeZone: utc))
        XCTAssertFalse(first.contains { $0.hasPrefix("3D shape number") })
        s.shapeSeed = 977
        let again = rows(MadeFrom(s, created: made, now: made, timeZone: utc))
        XCTAssertNotEqual(first, again, "the two versions look identical")
        XCTAssertTrue(again.contains("3D shape number: 977"))
    }

    /// An older mini leaves out what it didn't record rather than showing blanks. No model
    /// recorded is Pixal3D, the only one then; an unknown one isn't named.
    func testAnOlderMiniShowsOnlyWhatItHas() {
        var s = MiniSettings()
        s.source = .image; s.requested = Sizes()
        XCTAssertEqual(rows(MadeFrom(s, created: made, now: made, timeZone: utc)), ["Source: A picture", "3D model: Pixal3D", "Made: 21 Sep, 14:13"])
        s.model = "some-future-model"
        XCTAssertEqual(rows(MadeFrom(s, created: .distantPast, timeZone: utc)), ["Source: A picture"])
    }

    /// No settings at all (made before they existed): no section, and no model claimed.
    func testNoSettingsNoSection() {
        let m = MadeFrom(MiniSettings(), created: .distantPast)
        XCTAssertTrue(m.isEmpty)
        XCTAssertFalse(rows(MadeFrom(MiniSettings(), created: made, now: made, timeZone: utc)).contains { $0.hasPrefix("3D model") })
    }

    /// Recorded only for a cartoon, so settings.json for every other mini reads as before.
    func testCartoonIsSavedOnlyWhenSet() throws {
        let fx = try Fixture()
        try fx.modelFiles(); try fx.modelFiles(EngineDownload.cartoon)
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 2)))
        _ = try fx.mini("busy")
        try jobs.resize(name: "busy", sizes: Sizes(height: "32"))  // so these wait and nothing runs
        let picture = try fx.picture()
        try jobs.make(name: "toon", picture: .image(picture), restyle: true, seed: 1, sizes: Sizes(), model: EngineDownload.cartoon, cartoon: true)
        try jobs.make(name: "plain", picture: .image(picture), restyle: true, seed: 1, sizes: Sizes(), model: EngineDownload.cartoon)
        XCTAssertEqual(MiniSettings.load(try XCTUnwrap(Gallery.folder(fx.install.runs, "toon"))).cartoon, true)
        let plain = try XCTUnwrap(Gallery.folder(fx.install.runs, "plain"))
        XCTAssertNil(MiniSettings.load(plain).cartoon)
        XCTAssertFalse(try String(contentsOf: plain.appendingPathComponent("settings.json"), encoding: .utf8).contains("cartoon"))
        for n in jobs.queue.entries().map(\.name) { try jobs.remove(n) }
        jobs.waitUntilDone()
    }
}
