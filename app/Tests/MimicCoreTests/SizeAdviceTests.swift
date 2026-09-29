import XCTest
@testable import MimicCore

/// The web page's size card, number for number.
final class SizeAdviceTests: XCTestCase {
    func testGameScale() {
        XCTAssertEqual(SizeCard.gameHeight(real: "1.8", scale: 32), 32)
        XCTAssertEqual(SizeCard.gameHeight(real: "2.0", scale: 28), 31)
        XCTAssertEqual(SizeCard.gameHeight(real: "0.9", scale: 54), 27)
        for blank in ["", "0", "tall"] { XCTAssertEqual(SizeCard.gameHeight(real: blank, scale: 32), 32, blank) }
    }

    func testBestPrintFollowsTheNozzle() {
        var c = SizeCard(purpose: .display, nozzle: "0.2")
        XCTAssertEqual(c.height, 64)
        c.setNozzle("0.4"); XCTAssertEqual(c.height, 100)
        c.setNozzle("0.6"); XCTAssertEqual(c.height, 150)
        XCTAssertFalse(c.warns)
    }

    func testBase() {
        for (h, b) in [(32.0, 25.0), (100, 40), (150, 60), (200, 80), (15, 25)] { XCTAssertEqual(SizeCard.baseFor(h), b, "\(h)") }
    }

    func testCoarseNozzleWarning() {
        var c = SizeCard(purpose: .game, nozzle: "0.4")
        c.setScale(54); c.setRealHeight("1.67")  // 50.1 → 50
        XCTAssertFalse(c.warns)
        c.setRealHeight("1.62")  // 48.6 → 49
        XCTAssertTrue(c.warns)
        XCTAssertTrue(c.note.contains("At 49 mm, a 0.4 mm nozzle"), c.note)
        c.setNozzle("0.2")
        XCTAssertFalse(c.warns)
    }

    /// The note names the height worked out; the slider holds only its own range.
    func testNoteUsesTheUnclampedHeight() {
        var c = SizeCard(purpose: .game, nozzle: "0.4")
        c.setRealHeight("0.3")  // 5 mm
        XCTAssertTrue(c.note.contains("At 5 mm"), c.note)
        XCTAssertEqual(c.height, 15)
        XCTAssertEqual(c.base, 25)
    }

    func testNozzleSetsTheExtraThicknessUntilItsChosen() {
        var c = SizeCard(nozzle: "0.2")
        XCTAssertEqual(c.inflate, 0.08)
        c.setNozzle("0.4"); XCTAssertEqual(c.inflate, 0.16)
        c.setNozzle("0.6"); XCTAssertEqual(c.inflate, 0.24)
        XCTAssertNil(c.sizes.inflate, "an untouched thickness is print prep's to pick")
        c.setInflate(0.1); c.setNozzle("0.2")
        XCTAssertEqual(c.inflate, 0.1)
        XCTAssertEqual(c.sizes.inflate, "0.1")
    }

    func testTypedValuesAreClamped() {
        var c = SizeCard()
        c.setHeight(250); XCTAssertEqual(c.height, 200)
        c.setHeight(10); XCTAssertEqual(c.height, 15)
        c.setHeight(32.4); XCTAssertEqual(c.height, 32)
        c.setBase(90); XCTAssertEqual(c.base, 80)
        c.setInflate(0.5); XCTAssertEqual(c.inflate, 0.4)
        c.setInflate(-1); XCTAssertEqual(c.inflate, 0)
        c.setInflate(.nan); XCTAssertEqual(c.inflate, 0)
    }

    func testChoosingAgainResizesAndDraggingSticks() {
        var c = SizeCard(purpose: .game, nozzle: "0.2")
        c.setHeight(40); c.setBase(30)
        XCTAssertTrue(c.heightTouched && c.baseTouched)
        c.setScale(32)  // unchanged, but choosing again means "size it for me"
        XCTAssertEqual(c.height, 32); XCTAssertEqual(c.base, 25)
        XCTAssertFalse(c.heightTouched || c.baseTouched)
        c.setHeight(100)
        XCTAssertEqual(c.base, 40, "an untouched base follows the height")
        c.setPurpose(.display)
        XCTAssertEqual(c.height, 64)
    }

    func testLoadingAMinisSizes() {
        var c = SizeCard(purpose: .display, nozzle: "0.4")
        c.load(Sizes(height: "34", base: "30", nozzle: "0.2", noBase: true))
        XCTAssertEqual(c.sizes, Sizes(height: "34", base: "30", nozzle: "0.2", noBase: true))
        XCTAssertEqual(c.inflate, 0.08)
        XCTAssertTrue(c.heightTouched && c.baseTouched && !c.inflateTouched)
        c.load(Sizes(height: "50", nozzle: "0.4", inflate: "0.2"))
        // A new nozzle sizes it again first, as on the web: the base it left out is the suggestion.
        XCTAssertEqual(c.sizes, Sizes(height: "50", base: "40", nozzle: "0.4", inflate: "0.2"))
    }

    func testSizesPassTheRequestChecks() throws {
        XCTAssertEqual(try SizeCard().sizes.flags(), ["--height", "32.0", "--base", "25.0", "--nozzle", "0.4"])
    }

    func testNameFromDescription() {
        XCTAssertEqual(MakeAdvice.name(fromDescription: "A dwarf cleric holding a warhammer"), "dwarf-cleric-holding-a")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "  the Tiefling wizard"), "tiefling-wizard")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "an"), "an")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "anvil golem"), "anvil-golem")
    }

    func testPictureWarnings() {
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 1024, height: 1536), [])
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 400, height: 500).count, 1)
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 1150, height: 1000), [])
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 1160, height: 1000).count, 1)
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 300, height: 100).count, 2)
    }

    func testPrintTipsAndNowLine() {
        XCTAssertEqual(PrintTips(nozzle: "0.2").copyText, "Layer height 0.06–0.08 mm · Supports: Tree (auto) · Walls: 3–4 · Upright on its base, no brim")
        XCTAssertEqual(PrintTips(nozzle: "0.6").lines[0], "Layer height 0.2 mm. Supports: Tree (auto). Walls: 2–3.")
        XCTAssertEqual(PrintTips.nowLine(Sizes(height: "32", base: "25", nozzle: "0.2")),
                       "Now: 32 mm character · 25 mm base · made for a 0.2 mm nozzle")
        XCTAssertEqual(PrintTips.nowLine(Sizes()), "Now: 32 mm character · 25 mm base · made for a 0.4 mm nozzle")
    }
}

final class JobProgressTests: XCTestCase {
    func testNotes() {
        XCTAssertEqual(JobProgress.note(.prep, elapsed: 12), "About 30 seconds · 0:12 so far.")
        XCTAssertTrue(JobProgress.note(.generate, elapsed: 12 * 60).hasPrefix("About 7–10 minutes · 12:00 so far."))
        XCTAssertTrue(JobProgress.note(.generate, elapsed: 12 * 60 + 1).contains("Taking longer than usual"))
        XCTAssertTrue(JobProgress.note(.generate, elapsed: 25 * 60 + 1).contains("unusually slow"))
    }

    func testBar() {
        let start = Date(timeIntervalSince1970: 0)
        var s = JobStatus(name: "a", kind: .generate, step: 2, started: start)
        XCTAssertEqual(JobProgress.fraction(s, now: start.addingTimeInterval(270)), 0.5)
        XCTAssertEqual(JobProgress.fraction(s, now: start.addingTimeInterval(3000)), 0.95)
        s.kind = .prep
        XCTAssertEqual(JobProgress.fraction(s, now: start.addingTimeInterval(20)), 0.5)
        s.running = false; s.exit = 0
        XCTAssertEqual(JobProgress.fraction(s), 1)
        s.exit = 1
        XCTAssertEqual(JobProgress.fraction(s), 0)
    }

    func testDrawThingsCause() {
        var s = JobStatus(name: "a", kind: .generate, step: 1, started: Date(), running: false, exit: 1)
        XCTAssertFalse(JobProgress.drawThingsCaused(s))
        s.problem = DrawThingsError.notRunning.description
        XCTAssertTrue(JobProgress.drawThingsCaused(s))
    }
}
