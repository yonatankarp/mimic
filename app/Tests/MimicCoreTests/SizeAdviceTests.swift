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

    /// A comma decimal and feet used to count as 1.8 m without a word; heights here differ from
    /// 1.8 m so that shows. What still can't be read says so under the field.
    func testRealHeightInCommasAndFeet() {
        for (typed, mm) in [("1,50", 27.0), (" 2,0 ", 36), ("6'2\"", 33), ("6'2", 33), ("6’2”", 33), ("6 ft 2", 33),
                            ("6ft 2in", 33), ("5 feet 9 inches", 31), ("5'", 27), ("5 ft", 27), ("-1", 32)] {
            XCTAssertEqual(SizeCard.gameHeight(real: typed, scale: 32), mm, typed)
        }
        var c = SizeCard(purpose: .game)
        for fine in ["", "  ", "1,5", "6'2\""] { c.setRealHeight(fine); XCTAssertNil(c.realHeightProblem, fine) }
        for bad in ["tall", "0", "6'2\"x", "1.8.2"] {
            c.setRealHeight(bad)
            XCTAssertEqual(c.realHeightProblem, "Couldn't read that, so it's using 1.8 m. Try 1.75 or 5'9\".", bad)
            XCTAssertEqual(c.height, 32, bad)
        }
    }

    func testBestPrintFollowsTheNozzle() {
        var c = SizeCard(purpose: .display, nozzle: "0.2")
        XCTAssertEqual(c.height, 64)
        c.setNozzle("0.4"); XCTAssertEqual(c.height, 100)
        c.setNozzle("0.6"); XCTAssertEqual(c.height, 150)
        XCTAssertFalse(c.warns)
        XCTAssertEqual(c.note, "Sized so faces come out clearly on a 0.6 mm nozzle: about 150 mm tall. Chunky characters also look good a bit smaller.")
    }

    func testBase() {
        for (h, b) in [(32.0, 25.0), (100, 40), (150, 60), (200, 80), (15, 25)] { XCTAssertEqual(SizeCard.baseFor(h), b, "\(h)") }
    }

    /// One rule for an object's sizes, in the card and in Terminal (#219).
    func testAnObjectsSizesAreTheCardsInTerminalToo() {
        for (h, b) in [(80.0, 65.0), (60, 50), (63, 50), (64, 50), (66, 55), (20, 25), (200, 80)] { XCTAssertEqual(SizeCard.objectBase(h), b, "\(h)") }
        XCTAssertEqual(["0.2", "0.4", "0.6", nil].map { SizeCard.objectHeight(nozzle: $0) }, [50, 80, 120, 80])
        XCTAssertEqual(SizeCard.objectHeight(nozzle: "0.3"), 80, "a nozzle Mimic doesn't offer gets the 0.4 mm one's")
        for n in ["0.2", "0.4", "0.6"] {
            var card = SizeCard(purpose: .display, nozzle: n, kind: .object)
            card.noBase = false
            let typed = Sizes(nozzle: n)
            XCTAssertEqual(SizeCard.objectSizes(typed, addBase: true), Sizes(height: card.sizes.height, base: card.sizes.base, nozzle: n), n)
            XCTAssertEqual(SizeCard.objectSizes(typed, addBase: false), Sizes(height: card.sizes.height, nozzle: n, noBase: true), n)
        }
        XCTAssertEqual(SizeCard.objectSizes(Sizes(height: "60"), addBase: true), Sizes(height: "60", base: "50"))
        XCTAssertEqual(SizeCard.objectSizes(Sizes(base: "40"), addBase: true), Sizes(height: "80", base: "40"), "a typed base stays")
    }

    func testCoarseNozzleWarning() {
        var c = SizeCard(purpose: .game, nozzle: "0.4")
        c.setScale(54); c.setRealHeight("1.67")  // 50.1 → 50
        XCTAssertFalse(c.warns)
        XCTAssertEqual(c.note, "")
        c.setRealHeight("1.62")  // 48.6 → 49: a tip on 0.4, a warning on 0.6
        XCTAssertFalse(c.warns)
        XCTAssertTrue(c.note.hasPrefix("At 49 mm, a 0.4 mm nozzle softens faces"), c.note)
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
        XCTAssertEqual(c.note, "At 32 mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose Best print.")
        c.setScale(28)
        XCTAssertFalse(c.warns, "28 mm is the edge: still a tip")
        c.setRealHeight("1.7")  // 26 mm
        XCTAssertTrue(c.warns)
        XCTAssertTrue(c.note.hasPrefix("At 26 mm"), c.note)
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

    /// Resize keeps a mini's magnet hole too, and one without a base has none to keep.
    func testLoadingAMagnetHole() throws {
        var c = SizeCard()
        XCTAssertNil(c.sizes.magnet)
        c.load(Sizes(height: "32", base: "25", nozzle: "0.4", magnet: .mm8x3))
        XCTAssertEqual(c.sizes.magnet, .mm8x3)
        XCTAssertEqual(Array(try c.sizes.flags().suffix(2)), ["--magnet", "8x3"])
        c.load(Sizes(height: "32", nozzle: "0.4", noBase: true))
        XCTAssertNil(c.sizes.magnet, "no base, no hole")
        c.noBase = false
        XCTAssertEqual(c.sizes.magnet, .mm8x3)
        XCTAssertEqual(made(Sizes(height: "32", base: "25", shape: .hex, magnet: .mm5x2))[1], "Base: 25 mm hex, 5 × 2 mm magnet hole")
    }

    /// Resize starts from the last New Mini's choice; a loaded mini's sizes say what it was made for.
    func testLoadedSizesChooseWhatTheyMatch() {
        var c = SizeCard(purpose: .display, nozzle: "0.4")
        c.load(Sizes(height: "32", base: "25", nozzle: "0.4"))
        XCTAssertEqual(c.purpose, .game)
        XCTAssertEqual(c.scale, 32)
        XCTAssertEqual(c.note, "At 32 mm, a 0.4 mm nozzle softens faces a little. For sharper faces, use a 0.2 mm nozzle or choose Best print.")
        c.load(Sizes(height: "54", base: "25", nozzle: "0.6"))
        XCTAssertEqual(c.purpose, .game); XCTAssertEqual(c.scale, 54)
        c.load(Sizes(height: "100", base: "40", nozzle: "0.4"))
        XCTAssertEqual(c.purpose, .display)
        c.load(Sizes(height: "45", base: "20", nozzle: "0.4"))
        XCTAssertNil(c.purpose, "matches neither: neither is chosen")
        XCTAssertTrue(c.note.hasPrefix("At 45 mm"), c.note)
        c.setPurpose(.display)
        XCTAssertEqual(c.height, 100, "choosing one still sizes it again")

        // An object: its suggestion is its only choice, and the note is about the size it is.
        var o = SizeCard(purpose: .game, nozzle: "0.4", kind: .object)
        o.load(Sizes(height: "70", nozzle: "0.4", noBase: true))
        XCTAssertNil(o.purpose)
        XCTAssertEqual(o.note, "At 70 mm, a 0.4 mm nozzle softens fine details a little. For the clearest details, make it about 80 mm on its longest side.")
        o.load(Sizes(height: "120", nozzle: "0.4", noBase: true))
        XCTAssertNil(o.purpose); XCTAssertEqual(o.note, "")
        o.load(Sizes(height: "80", nozzle: "0.4", noBase: true))
        XCTAssertEqual(o.purpose, .display)
        XCTAssertTrue(o.note.contains("about 80 mm on its longest side"), o.note)
    }

    /// 35 mm (heroic) and 75 mm too. The bigger scales get the bases their minis come on; the
    /// smaller ones keep 25 mm, one map square. A tall character's base still grows with it.
    func testEveryScaleAndItsBase() {
        XCTAssertEqual(SizeCard.scales, [28, 32, 35, 54, 75])
        for (scale, base) in [(28, 25.0), (32, 25), (35, 25), (54, 40), (75, 50)] {
            var c = SizeCard(purpose: .game, nozzle: "0.4")
            c.setScale(scale)
            XCTAssertEqual([c.height, c.base], [Double(scale), base], "\(scale) mm")
            var loaded = SizeCard(purpose: .display, nozzle: "0.4")
            loaded.load(Sizes(height: String(scale), base: "25", nozzle: "0.4"))
            XCTAssertEqual(loaded.purpose, .game, "\(scale) mm")
            XCTAssertEqual(loaded.scale, scale)
        }
        var ogre = SizeCard(purpose: .game, nozzle: "0.4")
        ogre.setScale(75); ogre.setRealHeight("3")  // 125 mm
        XCTAssertEqual(ogre.base, 50)
        ogre.setHeight(150)
        XCTAssertEqual(ogre.base, 60, "the base follows a taller height")
        var display = SizeCard(purpose: .display, nozzle: "0.4")
        display.setScale(75)
        XCTAssertEqual(display.base, 40, "Best print's base is still by its height")
    }

    /// `--scale` in Terminal: the height and base the app's Game scale gives, for what wasn't typed.
    func testScaleInTerminal() {
        XCTAssertEqual(SizeCard.gameSizes(scale: 75, filling: Sizes()), Sizes(height: "75", base: "50"))
        XCTAssertEqual(SizeCard.gameSizes(scale: 35, filling: Sizes(nozzle: "0.2")), Sizes(height: "35", base: "25", nozzle: "0.2"))
        XCTAssertEqual(SizeCard.gameSizes(scale: 54, filling: Sizes(height: "120")), Sizes(height: "120", base: "50"),
                       "a typed height wins; the base suits it")
        XCTAssertEqual(SizeCard.gameSizes(scale: 54, filling: Sizes(base: "30")), Sizes(height: "54", base: "30"))
        XCTAssertEqual(SizeCard.gameSizes(scale: 54, filling: Sizes(noBase: true)), Sizes(height: "54", noBase: true))
        XCTAssertNil(SizeCard.gameSizes(scale: 40, filling: Sizes()))
        XCTAssertEqual(SizeCard.scaleChoices, "28, 32, 35, 54 or 75")
    }

    /// Anything else: sized by its longest side for the nozzle, no Game scale, no base unless asked.
    func testAnObjectCard() throws {
        var c = SizeCard(purpose: .game, nozzle: "0.2", kind: .object)
        XCTAssertEqual([c.height, c.base], [50, 40])
        XCTAssertTrue(c.noBase)
        XCTAssertEqual(c.note, "Sized so details come out clearly on a 0.2 mm nozzle: about 50 mm on its longest side. Change it to the size you want.")
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
        XCTAssertEqual(MakeAdvice.name(fromDescription: "A dwarf cleric holding a warhammer"), "Dwarf Cleric")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "an elf ranger with a longbow"), "Elf Ranger")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "orc chief with a big axe"), "Orc Chief")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "knight with a sword and a shield"), "Knight With Sword", "one word before the gear is too little to name it")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "  the Tiefling wizard"), "Tiefling Wizard")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "an"), "An")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "anvil golem"), "Anvil Golem")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "a half-orc bard, holding a lute"), "Half Orc Bard")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "!!!"), "")
    }

    /// Accents and other alphabets stay in the name it fills in (#128); only its folder is
    /// written in plain letters.
    func testNameFromDescriptionKeepsItsLetters() {
        XCTAssertEqual(MakeAdvice.name(fromDescription: "élodie the druid with a staff"), "Élodie Druid")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "Дракон"), "Дракон")
        XCTAssertEqual(MakeAdvice.name(fromDescription: "a McGregor ranger"), "McGregor Ranger")
        XCTAssertEqual(Rules.folderName(MakeAdvice.name(fromDescription: "élodie the druid")), "elodie-druid")
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

    /// A 20 mm cube is 8000 mm³: about 10 g of PLA, 3.3 m of 1.75 mm filament. Read back from
    /// its print file, and the same turned inside out.
    func testFilament() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cube-\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: url) }
        let cube = PrepTests.box(half: [10, 10, 10])
        try STL.write(cube, to: url)
        let volume = try XCTUnwrap(Filament.volume(stl: url))
        XCTAssertEqual(volume, 8000, accuracy: 1)
        var inside = cube
        inside.triangles = inside.triangles.map { SIMD3($0.x, $0.z, $0.y) }
        XCTAssertEqual(Filament.volume(inside.triangles.flatMap { [inside.positions[Int($0.x)], inside.positions[Int($0.y)], inside.positions[Int($0.z)]] }), 8000, accuracy: 1)
        XCTAssertEqual(Filament.words(volume), "Up to 10 g · 3.3 m")
        XCTAssertEqual(Filament.short(200), "up to 1 g", "never 0 g")
    }

    /// A project's filament is added up again whenever one of its minis changes; only print
    /// files whose time changed are read again (#340), each being tens of megabytes.
    func testFilamentReadsAgainOnlyAPrintFileThatChanged() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("cube-\(UUID().uuidString).stl")
        defer { try? fm.removeItem(at: url) }
        try STL.write(PrepTests.box(half: [10, 10, 10]), to: url)
        // A whole second, which setting it again gives back exactly.
        let made = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
        try fm.setAttributes([.modificationDate: made], ofItemAtPath: url.path)
        XCTAssertEqual(try XCTUnwrap(Filament.volume(stl: url)), 8000, accuracy: 1)
        // Twice the size, but with the old time: as if it hadn't changed.
        try STL.write(PrepTests.box(half: [20, 10, 10]), to: url)
        try fm.setAttributes([.modificationDate: made], ofItemAtPath: url.path)
        XCTAssertEqual(try XCTUnwrap(Filament.volume(stl: url)), 8000, accuracy: 1, "an unchanged print file was read again")
        try fm.setAttributes([.modificationDate: made.addingTimeInterval(60)], ofItemAtPath: url.path)
        XCTAssertEqual(try XCTUnwrap(Filament.volume(stl: url)), 16000, accuracy: 1, "a resized print file kept its old figure")
    }

    /// The extra thickness a nozzle gets when it isn't chosen by hand: 40% of the nozzle, to the
    /// hundredth of a mm. A nozzle that can't be read counts as 0.4.
    func testTheExtraThicknessFollowsTheNozzle() {
        XCTAssertEqual(SizeCard.inflateFor("0.2"), 0.08)
        XCTAssertEqual(SizeCard.inflateFor("0.4"), 0.16)
        XCTAssertEqual(SizeCard.inflateFor("0.6"), 0.24)
        XCTAssertEqual(SizeCard.inflateFor("0.8"), 0.32, "worked out, not looked up")
        XCTAssertEqual(SizeCard.inflateFor("wide"), 0.16)
        XCTAssertEqual(SizeCard.inflateFor(""), 0.16)
    }

    /// PLA at 1.24 g/cm³, on 1.75 mm filament.
    func testGramsAndMetresOfFilament() {
        XCTAssertEqual(Filament.grams(0), 0)
        XCTAssertEqual(Filament.grams(1000), 1.24, accuracy: 1e-9)
        XCTAssertEqual(Filament.grams(8000), 9.92, accuracy: 1e-9)
        XCTAssertEqual(Filament.metres(1000), 0.41575, accuracy: 1e-5)
        XCTAssertEqual(Filament.short(8000), "up to 10 g", "9.92 g rounds to 10")
        XCTAssertEqual(Filament.short(0), "up to 1 g")
        XCTAssertEqual(Filament.words(0), "Up to 1 g · 0.1 m", "never 0 m either")
    }

    private func made(_ sizes: Sizes, _ kind: MiniKind = .character) -> [String] {
        PrintTips.made(sizes, kind: kind).map { "\($0.label): \($0.value)" }
    }
}

final class JobProgressTests: XCTestCase {
    func testBar() {
        let start = Date(timeIntervalSince1970: 0)
        let e = Estimate(steps: [.print: 60], learned: false)
        var s = JobStatus(name: "a", kind: .prep, step: .print, started: start)
        XCTAssertEqual(JobProgress.fraction(s, estimate: e, now: start.addingTimeInterval(30)), 0.5)
        XCTAssertEqual(JobProgress.fraction(s, estimate: e, now: start.addingTimeInterval(3000)), 0.95)
        s.running = false; s.exit = 0
        XCTAssertEqual(JobProgress.fraction(s, estimate: e), 1)
        s.exit = 1
        XCTAssertEqual(JobProgress.fraction(s, estimate: e), 0)
    }

    func testDrawThingsCause() {
        var s = JobStatus(name: "a", kind: .generate, step: .picture, started: Date(), running: false, exit: 1)
        XCTAssertFalse(JobProgress.drawThingsCaused(s))
        s.problem = DrawThingsError.notRunning.description
        XCTAssertTrue(JobProgress.drawThingsCaused(s))
        s.problem = DrawThingsError.timedOut.description
        XCTAssertFalse(JobProgress.drawThingsCaused(s), "on but slow or stuck: setup isn't the cause")
    }
}
