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
        XCTAssertEqual(c.note, "✨ Sized so faces come out clearly on a 0.6 mm nozzle: about 150 mm tall. Chunky characters also look good a bit smaller.")
    }

    func testBase() {
        for (h, b) in [(32.0, 25.0), (100, 40), (150, 60), (200, 80), (15, 25)] { XCTAssertEqual(SizeCard.baseFor(h), b, "\(h)") }
    }

    func testCoarseNozzleWarning() {
        var c = SizeCard(purpose: .game, nozzle: "0.4")
        c.setScale(54); c.setRealHeight("1.67")  // 50.1 → 50
        XCTAssertFalse(c.warns)
        XCTAssertEqual(c.note, "")
        c.setRealHeight("1.62")  // 48.6 → 49: a tip on 0.4, a warning on 0.6
        XCTAssertFalse(c.warns)
        XCTAssertTrue(c.note.hasPrefix("💡 At 49 mm, a 0.4 mm nozzle softens faces"), c.note)
        c.setNozzle("0.6")
        XCTAssertTrue(c.warns)
        XCTAssertTrue(c.note.contains("At 49 mm, a 0.6 mm nozzle turns faces into bumps"), c.note)
        c.setRealHeight("")  // 54 mm: 0.6's sweet spot
        XCTAssertFalse(c.warns); XCTAssertEqual(c.note, "")
        c.setNozzle("0.2"); c.setRealHeight("1.62")
        XCTAssertFalse(c.warns); XCTAssertEqual(c.note, "")
    }

    /// The default card (32 mm on a 0.4 nozzle) gets a tip, not an orange warning.
    func testDefaultGameScaleIsATipNotAWarning() {
        var c = SizeCard(purpose: .game, nozzle: "0.4")
        XCTAssertFalse(c.warns)
        XCTAssertEqual(c.note, "💡 At 32 mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose ✨ Best print.")
        c.setScale(28)
        XCTAssertFalse(c.warns, "28 mm is the edge: still a tip")
        c.setRealHeight("1.7")  // 26 mm
        XCTAssertTrue(c.warns)
        XCTAssertTrue(c.note.hasPrefix("⚠️ At 26 mm"), c.note)
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
        // A new nozzle sizes it again first, as on the web: the base it left out is the suggestion,
        // here for the 34 mm it was, since 34 mm matched neither choice.
        XCTAssertEqual(c.sizes, Sizes(height: "50", base: "25", nozzle: "0.4", inflate: "0.2"))
    }

    /// Resize keeps a mini's base shape; one without a base keeps the card's, for if one is added.
    func testLoadingABaseShape() {
        var c = SizeCard()
        c.load(Sizes(height: "32", base: "25", nozzle: "0.4", shape: .hex, style: .stone))
        XCTAssertEqual(c.sizes.shape, .hex)
        XCTAssertEqual(c.sizes.style, .stone)
        c.load(Sizes(height: "32", nozzle: "0.4", noBase: true))
        XCTAssertEqual(c.shape, .hex)
        XCTAssertEqual(c.sizes.shape, .round, "no base, no shape")
        c.noBase = false
        XCTAssertEqual(c.sizes.shape, .hex)
    }

    /// Resize starts from the last New Mini's choice; a loaded mini's sizes say what it was made for.
    func testLoadedSizesChooseWhatTheyMatch() {
        var c = SizeCard(purpose: .display, nozzle: "0.4")
        c.load(Sizes(height: "32", base: "25", nozzle: "0.4"))
        XCTAssertEqual(c.purpose, .game)
        XCTAssertEqual(c.scale, 32)
        XCTAssertEqual(c.note, "💡 At 32 mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose ✨ Best print.")
        c.load(Sizes(height: "54", base: "25", nozzle: "0.6"))
        XCTAssertEqual(c.purpose, .game); XCTAssertEqual(c.scale, 54)
        c.load(Sizes(height: "100", base: "40", nozzle: "0.4"))
        XCTAssertEqual(c.purpose, .display)
        c.load(Sizes(height: "45", base: "20", nozzle: "0.4"))
        XCTAssertNil(c.purpose, "matches neither: neither is chosen")
        XCTAssertTrue(c.note.hasPrefix("💡 At 45 mm"), c.note)
        c.setPurpose(.display)
        XCTAssertEqual(c.height, 100, "choosing one still sizes it again")

        // An object: its suggestion is its only choice, and the note is about the size it is.
        var o = SizeCard(purpose: .game, nozzle: "0.4", kind: .object)
        o.load(Sizes(height: "70", nozzle: "0.4", noBase: true))
        XCTAssertNil(o.purpose)
        XCTAssertEqual(o.note, "💡 At 70 mm, a 0.4 mm nozzle softens fine details a little. For the clearest details, make it about 80 mm on its longest side.")
        o.load(Sizes(height: "120", nozzle: "0.4", noBase: true))
        XCTAssertNil(o.purpose); XCTAssertEqual(o.note, "")
        o.load(Sizes(height: "80", nozzle: "0.4", noBase: true))
        XCTAssertEqual(o.purpose, .display)
        XCTAssertTrue(o.note.contains("about 80 mm on its longest side"), o.note)
    }

    /// Anything else: sized by its longest side for the nozzle, no Game scale, no base unless asked.
    func testAnObjectCard() throws {
        var c = SizeCard(purpose: .game, nozzle: "0.2", kind: .object)
        XCTAssertEqual([c.height, c.base], [50, 40])
        XCTAssertTrue(c.noBase)
        XCTAssertEqual(c.note, "✨ Sized so details come out clearly on a 0.2 mm nozzle: about 50 mm on its longest side. Change it to the size you want.")
        c.setScale(54); c.setRealHeight("3")
        XCTAssertEqual(c.height, 50, "Game scale doesn't size an object")
        c.setNozzle("0.4"); XCTAssertEqual(c.height, 80)
        c.setNozzle("0.6"); XCTAssertEqual(c.height, 120)
        XCTAssertEqual(try c.sizes.flags(), ["--height", "120.0", "--base", "80.0", "--nozzle", "0.6", "--no-base"])
        c.noBase = false
        XCTAssertEqual(c.sizes.noBase, false)
        c.setKind(.character)
        XCTAssertFalse(c.noBase)
        var character = SizeCard(purpose: .game, nozzle: "0.6"); character.setScale(54); character.setRealHeight("3")
        XCTAssertEqual(c.sizes, character.sizes, "back to a character: exactly a character's card")
        c.setKind(.object)
        c.load(Sizes(height: "70", nozzle: "0.6", noBase: true))  // Resize: the kind first, then what it is now
        XCTAssertEqual(c.sizes.height, "70")
    }

    func testObjectAdvice() {
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 1600, height: 1000, kind: .object), [], "a wide object is fine")
        XCTAssertEqual(MakeAdvice.pictureWarnings(width: 400, height: 300, kind: .object).count, 1)
        let tips = PrintTips(nozzle: "0.2", kind: .object)
        XCTAssertEqual(tips.copyText, "Layer height 0.06–0.08 mm · Supports: Tree (auto) · Walls: 3–4 · Flat side down")
        XCTAssertFalse(tips.lines.joined().contains("face"))
        XCTAssertEqual(made(Sizes(height: "80", base: "25", nozzle: "0.4", noBase: true), .object),
                       ["Longest side: 80 mm", "Base: None", "Nozzle: 0.4 mm"])
        XCTAssertEqual(made(Sizes(height: "80", base: "60", nozzle: "0.4"), .object), ["Longest side: 80 mm", "Base: 60 mm", "Nozzle: 0.4 mm"])
    }

    func testSizesPassTheRequestChecks() throws {
        XCTAssertEqual(try SizeCard().sizes.flags(), ["--height", "32.0", "--base", "25.0", "--nozzle", "0.4"])
    }

    func testNameFromDescription() {
        XCTAssertEqual(MakeAdvice.name(fromDescription: "A dwarf cleric holding a warhammer"), "dwarf-cleric")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "an elf ranger with a longbow"), "elf-ranger")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "orc chief with a big axe"), "orc-chief")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "knight with a sword and a shield"), "knight-with-sword", "one word before the gear is too little to name it")
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

    func testPrintTipsAndMadeSizes() {
        XCTAssertEqual(PrintTips(nozzle: "0.2").copyText, "Layer height 0.06–0.08 mm · Supports: Tree (auto) · Walls: 3–4 · Upright on its base, no brim")
        XCTAssertEqual(PrintTips(nozzle: "0.6").lines[0], "Layer height 0.2 mm. Supports: Tree (auto). Walls: 2–3.")
        XCTAssertEqual(made(Sizes(height: "32", base: "25", nozzle: "0.2")), ["Character: 32 mm", "Base: 25 mm", "Nozzle: 0.2 mm"])
        XCTAssertEqual(made(Sizes(height: "0", noBase: true)), ["Character: 32 mm", "Base: 25 mm", "Nozzle: 0.4 mm"],
                       "missing or 0 is the default; a character always has a base")
        XCTAssertEqual(made(Sizes(height: "32", base: "25", shape: .hex))[1], "Base: 25 mm hex")
        XCTAssertEqual(made(Sizes(height: "32", base: "25", shape: .square))[1], "Base: 25 mm square")
        XCTAssertEqual(made(Sizes(height: "32", base: "25", style: .wood))[1], "Base: 25 mm, wooden floor")
        XCTAssertEqual(PrintTips.shortLine(Sizes(height: "54.4", nozzle: "0.2")), "54 mm · 0.2 mm nozzle")
        XCTAssertEqual(PrintTips.shortLine(Sizes()), "32 mm · 0.4 mm nozzle")
    }

    private func made(_ sizes: Sizes, _ kind: MiniKind = .character) -> [String] {
        PrintTips.made(sizes, kind: kind).map { "\($0.label): \($0.value)" }
    }
}

final class JobProgressTests: XCTestCase {
    func testBar() {
        let start = Date(timeIntervalSince1970: 0)
        let e = Estimate(steps: [3: 60], learned: false)
        var s = JobStatus(name: "a", kind: .prep, step: 3, started: start)
        XCTAssertEqual(JobProgress.fraction(s, estimate: e, now: start.addingTimeInterval(30)), 0.5)
        XCTAssertEqual(JobProgress.fraction(s, estimate: e, now: start.addingTimeInterval(3000)), 0.95)
        s.running = false; s.exit = 0
        XCTAssertEqual(JobProgress.fraction(s, estimate: e), 1)
        s.exit = 1
        XCTAssertEqual(JobProgress.fraction(s, estimate: e), 0)
    }

    func testDrawThingsCause() {
        var s = JobStatus(name: "a", kind: .generate, step: 1, started: Date(), running: false, exit: 1)
        XCTAssertFalse(JobProgress.drawThingsCaused(s))
        s.problem = DrawThingsError.notRunning.description
        XCTAssertTrue(JobProgress.drawThingsCaused(s))
    }
}
