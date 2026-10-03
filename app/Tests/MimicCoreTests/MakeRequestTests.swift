import XCTest
@testable import MimicCore

/// `mimic make`, `resize`, `retry`, `make-another`, `import` and `queue move|remove` as typed
/// (#192): every option, every refusal in its own words, and which refusal wins when there are two.
final class MakeRequestTests: XCTestCase {
    private func parse(_ args: String..., engineReady: Bool = true) throws -> MakeRequest {
        try MakeRequest.parse(args, engineReady: engineReady)
    }

    /// The refusal, as `mimic` says it.
    private func refusal(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do { _ = try body(); XCTFail("not refused", file: file, line: line); return nil } catch { return "\(error)" }
    }

    /// Parsed, then checked with the sizes and kind as typed: what make, import and the rest do.
    private func checked(_ args: String...) throws -> Sizes {
        let r = try MakeRequest.parse(args)
        return try r.checkedSizes(r.sizes, object: r.object)
    }

    func testMakeTakesANameAsTheAppDoes() throws {
        let typed = try parse("make", "Élodie", "a dwarf cleric")
        XCTAssertEqual(typed.command, .make)
        XCTAssertEqual(typed.of, "elodie")
        XCTAssertEqual(typed.shown, "Élodie")
        XCTAssertEqual(typed.description, "a dwarf cleric")
        let folder = try parse("make", "dwarf-cleric", "--image", "dwarf.png")
        XCTAssertEqual(folder.of, "dwarf-cleric")
        XCTAssertNil(folder.shown)
        XCTAssertEqual(folder.image, "dwarf.png")
        XCTAssertNil(folder.description)
    }

    func testTheMiniItIsAbout() throws {
        XCTAssertEqual(try parse("resize", "Élodie").of, "elodie")
        XCTAssertEqual(try parse("retry", "dwarf-cleric").of, "dwarf-cleric")
        XCTAssertEqual(try parse("make-another", "Raven Display").of, "raven-display")
        XCTAssertEqual(try parse("make-another", "Raven Display").command, .makeAnother)
        // A file, as typed: its name comes from the minis folder.
        XCTAssertEqual(try parse("import", "Models/Élodie Bust.glb").of, "Models/Élodie Bust.glb")
        XCTAssertEqual(try parse("import", "a.stl").command, .import)
        XCTAssertEqual(try parse("retry", "a").command, .retry)
        XCTAssertEqual(try parse("resize", "a").command, .resize)
    }

    func testResizeAllTakesItsProject() throws {
        let r = try parse("resize", "--project", "Tiefling Party", "--height", "40")
        XCTAssertEqual(r.command, .resizeAll(project: "Tiefling Party"))
        XCTAssertNil(r.project, "the project it resizes, not one to put it in")
        XCTAssertEqual(r.of, "")
        XCTAssertEqual(r.sizes.height, "40")
        XCTAssertEqual(try parse("resize", "--project", "A", "--project", "B").command, .resizeAll(project: "B"))
        XCTAssertEqual(try checked("resize", "--project", "A"), Sizes(), "resize --project isn't refused as --project")
        XCTAssertEqual(refusal { try self.parse("resize", "--project") }, "--project needs a project's name")
    }

    func testDefaults() throws {
        let r = try parse("make", "a", "a dwarf")
        XCTAssertEqual(r.sizes, Sizes())
        XCTAssertNil(r.seed)
        XCTAssertNil(r.model)
        XCTAssertNil(r.scale)
        XCTAssertNil(r.project)
        XCTAssertNil(r.image)
        XCTAssertEqual(r.sides, [:])
        XCTAssertFalse(r.object || r.addBase || r.restyle || r.improve || r.wait || r.newShape)
        XCTAssertFalse(r.shapeGiven || r.styleGiven || r.magnetGiven)
    }

    func testEveryOption() throws {
        let r = try parse("make", "a", "--image", "front.png", "--back", "back.png", "--left", "left.png", "--right", "right.png",
                          "--height", "40", "--base", "30", "--nozzle", "0.2", "--inflate", "0.1", "--base-shape", "hex",
                          "--base-style", "stone", "--magnet", "6x2", "--scale", "54", "--add-base", "--restyle", "--improve",
                          "--wait", "--new-shape", "--seed", "7", "--project", "Tiefling Party", "--model", "pixal3d-sv", "--object")
        XCTAssertEqual(r.image, "front.png")
        XCTAssertEqual(r.sides, [.back: URL(fileURLWithPath: "back.png"), .left: URL(fileURLWithPath: "left.png"),
                                 .right: URL(fileURLWithPath: "right.png")])
        XCTAssertEqual(r.sizes, Sizes(height: "40", base: "30", nozzle: "0.2", inflate: "0.1", shape: .hex, style: .stone, magnet: .mm6x2))
        XCTAssertTrue(r.shapeGiven && r.styleGiven && r.magnetGiven)
        XCTAssertEqual(r.scale, 54)
        XCTAssertTrue(r.object && r.addBase && r.restyle && r.improve && r.wait && r.newShape)
        XCTAssertEqual(r.seed, 7)
        XCTAssertEqual(r.project, "Tiefling Party")
        XCTAssertEqual(r.model?.id, "pixal3d-sv")
        XCTAssertEqual(try parse("resize", "a", "--size", "80").sizes.height, "80", "--size is --height")
        XCTAssertTrue(try parse("resize", "a", "--no-base").sizes.noBase)
        XCTAssertEqual(try parse("make", "a", "x", "--model", "trellis2-q8").model?.id, "trellis2-q8")
        for scale in SizeCard.scales { XCTAssertEqual(try parse("make", "a", "x", "--scale", "\(scale)").scale, scale) }
        for shape in BaseShape.allCases { XCTAssertEqual(try parse("resize", "a", "--base-shape", shape.rawValue).sizes.shape, shape) }
        for style in BaseStyle.allCases { XCTAssertEqual(try parse("resize", "a", "--base-style", style.rawValue).sizes.style, style) }
        for magnet in Magnet.allCases { XCTAssertEqual(try parse("resize", "a", "--magnet", magnet.rawValue).sizes.magnet, magnet) }
    }

    func testMagnetNoneIsGiven() throws {
        let r = try parse("resize", "a", "--magnet", "none")
        XCTAssertNil(r.sizes.magnet)
        XCTAssertTrue(r.magnetGiven, "so a resize takes the magnet off")
    }

    func testTheLastOfARepeatedOptionWins() throws {
        XCTAssertEqual(try parse("resize", "a", "--height", "30", "--height", "40").sizes.height, "40")
        XCTAssertEqual(try parse("make", "a", "x", "--seed", "1", "--seed", "2").seed, 2)
    }

    /// A size or picture given as the last word, with no value, is refused rather than quietly
    /// left out, which made the mini at another size (#329).
    func testAnOptionWithNoValueIsRefused() throws {
        for flag in ["--height", "--size", "--base", "--inflate"] {
            XCTAssertEqual(refusal { try self.parse("resize", "a", flag) }, "\(flag) needs a number", flag)
        }
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--nozzle") }, "--nozzle needs 0.2, 0.4 or 0.6")
        XCTAssertEqual(refusal { try self.parse("make", "a", "--image") }, "--image needs a picture")
    }

    func testADescriptionIsTakenOnce() throws {
        XCTAssertEqual(try parse("resize", "a", "words").description, "words")
        XCTAssertEqual(refusal { try self.parse("make", "a", "a dwarf", "a second one") }, "unknown option: a second one\n" + Usage.text)
    }

    func testUnknownOptions() {
        XCTAssertEqual(refusal { try self.parse("make", "a", "x", "--sideways") }, "unknown option: --sideways\n" + Usage.text)
        XCTAssertEqual(refusal { try self.parse("resize", "a", "-h") }, "unknown option: -h\n" + Usage.text)
        // --json is only for the listings.
        XCTAssertEqual(refusal { try self.parse("retry", "a", "--json") }, "unknown option: --json\n" + Usage.text)
    }

    func testUsage() {
        for args in [["make"], ["make", "--height", "40"], ["resize"], ["resize", "--height", "40"], ["retry"], ["retry", "-a"],
                     ["make-another", "--new-shape"], ["import"], ["import", "--object"], ["make", "--project", "P"], [], ["list"]] {
            XCTAssertEqual(refusal { try MakeRequest.parse(args) }, Usage.text, "\(args)")
        }
    }

    func testNoName() {
        XCTAssertEqual(refusal { try self.parse("make", "   ", "a dwarf") }, "Give the mini a name.")
        XCTAssertEqual(refusal { try self.parse("make", "", "a dwarf") }, "Give the mini a name.")
    }

    func testSetupComesBeforeTheOptions() throws {
        let setUp = "Mimic needs to finish setting up. Open the Mimic app: it downloads what's missing."
        XCTAssertEqual(refusal { try self.parse("make", "a", "x", engineReady: false) }, setUp)
        XCTAssertEqual(refusal { try self.parse("retry", "a", engineReady: false) }, setUp)
        XCTAssertEqual(refusal { try self.parse("make-another", "a", engineReady: false) }, setUp)
        XCTAssertEqual(refusal { try self.parse("make", "a", "--scale", "99", engineReady: false) }, setUp)
        // Print prep only.
        XCTAssertNoThrow(try parse("resize", "a", engineReady: false))
        XCTAssertNoThrow(try parse("resize", "--project", "P", engineReady: false))
        XCTAssertNoThrow(try parse("import", "a.glb", engineReady: false))
        // What's typed wrong before the options is said first.
        XCTAssertEqual(refusal { try self.parse("make", engineReady: false) }, Usage.text)
        XCTAssertEqual(refusal { try self.parse("make", " ", engineReady: false) }, "Give the mini a name.")
    }

    func testOptionsTypedWrong() {
        let scale = "--scale needs 28, 32, 35, 54 or 75"
        for value in [["30"], ["big"], []] {
            XCTAssertEqual(refusal { try MakeRequest.parse(["make", "a", "x", "--scale"] + value) }, scale)
        }
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--base-shape", "oval") }, "--base-shape needs round, square or hex")
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--base-shape") }, "--base-shape needs round, square or hex")
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--base-style", "marble") }, "--base-style needs plain, stone, wood or cobble")
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--base-style") }, "--base-style needs plain, stone, wood or cobble")
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--magnet", "10x5") }, "--magnet needs 5x2, 6x2, 8x3 or none")
        XCTAssertEqual(refusal { try self.parse("resize", "a", "--magnet") }, "--magnet needs 5x2, 6x2, 8x3 or none")
        XCTAssertEqual(refusal { try self.parse("make", "a", "--image", "f.png", "--back") }, "--back needs a picture")
        XCTAssertEqual(refusal { try self.parse("make", "a", "--image", "f.png", "--left") }, "--left needs a picture")
        XCTAssertEqual(refusal { try self.parse("make", "a", "--image", "f.png", "--right") }, "--right needs a picture")
        XCTAssertEqual(refusal { try self.parse("make-another", "a", "--seed", "lucky") }, "--seed needs a number")
        XCTAssertEqual(refusal { try self.parse("make-another", "a", "--seed") }, "--seed needs a number")
        XCTAssertEqual(refusal { try self.parse("make", "a", "x", "--project") }, "--project needs a project's name")
        let model = "--model needs one of: trellis2-q8, pixal3d-sv (see mimic models)"
        XCTAssertEqual(refusal { try self.parse("make", "a", "x", "--model", "dall-e") }, model)
        XCTAssertEqual(refusal { try self.parse("make", "a", "x", "--model") }, model)
        // The first one typed wrong is the one said.
        XCTAssertEqual(refusal { try self.parse("make", "a", "x", "--seed", "z", "--scale", "1") }, "--seed needs a number")
    }

    func testProjectIsForMakeAndImport() throws {
        let said = "--project is for mimic make, import and resize --project; mimic move moves a mini"
        XCTAssertEqual(refusal { try self.checked("resize", "a", "--project", "P") }, said)
        XCTAssertEqual(refusal { try self.checked("retry", "a", "--project", "P") }, said)
        XCTAssertEqual(refusal { try self.checked("make-another", "a", "--project", "P") }, said)
        XCTAssertNoThrow(try checked("make", "a", "x", "--project", "P"))
        XCTAssertNoThrow(try checked("import", "a.glb", "--project", "P"))
    }

    func testImportTakesTheModelAsItIs() throws {
        let said = "mimic import takes the model as it is: only size options, --object, --add-base and --project"
        for extra in [["--image", "f.png"], ["--restyle"], ["--improve"], ["--seed", "3"], ["--model", "pixal3d-sv"], ["--new-shape"], ["words"]] {
            XCTAssertEqual(refusal { try self.checkedArray(["import", "a.glb"] + extra) }, said, "\(extra)")
        }
        XCTAssertNoThrow(try checked("import", "a.glb", "--object", "--add-base", "--height", "60", "--project", "P", "--wait"))
    }

    private func checkedArray(_ args: [String]) throws -> Sizes {
        let r = try MakeRequest.parse(args)
        return try r.checkedSizes(r.sizes, object: r.object)
    }

    func testNewShapeIsForMakeAnother() throws {
        for args in [["make", "a", "x"], ["resize", "a"], ["retry", "a"], ["resize", "--project", "P"]] {
            XCTAssertEqual(refusal { try self.checkedArray(args + ["--new-shape"]) }, "--new-shape is for mimic make-another", "\(args)")
        }
        XCTAssertNoThrow(try checked("make-another", "a", "--new-shape", "--seed", "3"))
    }

    func testSidesGoWithAFrontPicture() throws {
        let said = "--back, --left and --right go with mimic make … --image <front picture>"
        XCTAssertEqual(refusal { try self.checked("make", "a", "a dwarf", "--back", "b.png") }, said)
        XCTAssertEqual(refusal { try self.checked("resize", "a", "--left", "l.png") }, said)
        XCTAssertEqual(refusal { try self.checked("make-another", "a", "--right", "r.png") }, said)
        XCTAssertNoThrow(try checked("make", "a", "--image", "f.png", "--back", "b.png"))
    }

    func testScaleIsForCharacters() throws {
        let said = "--scale is for characters; give an object's longest side with --size"
        XCTAssertEqual(refusal { try self.checked("make", "a", "a teapot", "--object", "--scale", "28") }, said)
        // A resize keeps what the mini is: an object, though --object wasn't typed.
        let resize = try parse("resize", "a", "--scale", "28")
        XCTAssertEqual(refusal { try resize.checkedSizes(resize.sizes, object: true) }, said)
    }

    /// --change (#156): what to change in a picture, for a make from one and make-another.
    func testChangeGoesWithAPicture() throws {
        XCTAssertEqual(try parse("make", "a", "--image", "f.png", "--change", "  close the cape  ").change, "close the cape")
        XCTAssertEqual(try parse("make-another", "a", "--new-shape", "--change", "no helmet").change, "no helmet")
        XCTAssertNil(try parse("make", "a", "--image", "f.png").change)
        for given in [["--change"], ["--change", "  "]] {
            XCTAssertEqual(refusal { try self.checkedArray(["make", "a", "--image", "f.png"] + given) }, "--change needs what to change, in quotes")
        }
        let said = "--change goes with mimic make … --image and mimic make-another; for a description, change the description"
        for args in [["make", "a", "a dwarf"], ["resize", "a"], ["retry", "a"], ["resize", "--project", "P"]] {
            XCTAssertEqual(refusal { try self.checkedArray(args + ["--change", "x"]) }, said, "\(args)")
        }
        XCTAssertEqual(refusal { try self.checked("import", "a.glb", "--change", "x") },
                       "mimic import takes the model as it is: only size options, --object, --add-base and --project")
        XCTAssertNoThrow(try checked("make", "a", "--image", "f.png", "--change", "x"))
        XCTAssertNoThrow(try checked("make-another", "a", "--change", "x"))
    }

    func testImproveWorksOnADescription() throws {
        XCTAssertEqual(refusal { try self.checked("make", "a", "--image", "f.png", "--improve") }, "--improve works on a description, not --image")
        XCTAssertNoThrow(try checked("make", "a", "a dwarf", "--improve"))
    }

    /// An option a command doesn't take is refused, not ignored: retrying with --height made the
    /// mini at its old size, with no warning (#327).
    func testOptionsACommandDoesNotTakeAreRefused() throws {
        for (args, option) in [(["retry", "a", "--height", "40", "--seed", "7"], "--height"), (["retry", "a", "--model", "trellis2-q8"], "--model"),
                               (["make-another", "a", "--height", "40"], "--height"), (["make-another", "a", "--model", "trellis2-q8"], "--model"),
                               (["make-another", "a", "--object"], "--object"), (["make-another", "a", "--restyle"], "--restyle"),
                               (["resize", "a", "--seed", "5"], "--seed"), (["resize", "a", "--image", "a.png"], "--image"),
                               (["resize", "a", "--object"], "--object"), (["resize", "--project", "P", "--model", "pixal3d-sv"], "--model")] {
            let verb = args[0]
            XCTAssertEqual(refusal { try self.checkedArray(args) }, "mimic \(verb) doesn't take \(option) (mimic --help lists what each command takes)", "\(args)")
        }
        // A word that isn't an option, as make refuses a second description.
        for args in [["retry", "a", "foo"], ["resize", "a", "desc"], ["make-another", "a", "desc"]] {
            XCTAssertEqual(refusal { try self.checkedArray(args) }, "unknown option: \(args[2])\n" + Usage.text, "\(args)")
        }
        XCTAssertNoThrow(try checked("retry", "a", "--wait"))
        XCTAssertNoThrow(try checked("make-another", "a", "--new-shape", "--seed", "3", "--change", "x", "--wait"))
        XCTAssertNoThrow(try checked("resize", "a", "--height", "40", "--size", "40", "--scale", "32", "--base", "30", "--base-shape", "hex",
                                     "--base-style", "stone", "--magnet", "5x2", "--nozzle", "0.2", "--inflate", "0.1", "--no-base",
                                     "--add-base", "--wait"))
        XCTAssertNoThrow(try checked("resize", "--project", "P", "--height", "40", "--wait"))
    }

    func testWhichRefusalComesFirst() {
        XCTAssertEqual(refusal { try self.checked("retry", "a", "--project", "P", "--new-shape") },
                       "--project is for mimic make, import and resize --project; mimic move moves a mini")
        XCTAssertEqual(refusal { try self.checked("import", "a.glb", "--new-shape", "--back", "b.png") },
                       "mimic import takes the model as it is: only size options, --object, --add-base and --project")
        XCTAssertEqual(refusal { try self.checked("make", "a", "--image", "f.png", "--new-shape", "--back", "b.png") },
                       "--new-shape is for mimic make-another")
        XCTAssertEqual(refusal { try self.checked("make", "a", "--back", "b.png", "--object", "--scale", "28") },
                       "--back, --left and --right go with mimic make … --image <front picture>")
        XCTAssertEqual(refusal { try self.checked("make", "a", "--image", "f.png", "--improve", "--object", "--scale", "28") },
                       "--scale is for characters; give an object's longest side with --size")
    }

    func testScaleSizesItAsTheAppDoes() throws {
        XCTAssertEqual(try checked("make", "a", "x", "--scale", "54"), SizeCard.gameSizes(scale: 54, filling: Sizes()))
        let typed = Sizes(height: "40", nozzle: "0.2")
        XCTAssertEqual(try checked("make", "a", "x", "--scale", "28", "--height", "40", "--nozzle", "0.2"),
                       SizeCard.gameSizes(scale: 28, filling: typed))
        XCTAssertEqual(try checked("make", "a", "x", "--height", "40"), Sizes(height: "40"), "nothing added without --scale")
    }

    func testAnObjectsSizes() throws {
        // No base unless asked for one, and its longest side from the nozzle.
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object"), Sizes(height: SizeCard.text(80), noBase: true))
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--nozzle", "0.2"),
                       Sizes(height: SizeCard.text(50), nozzle: "0.2", noBase: true))
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--size", "60"), Sizes(height: "60", noBase: true))
        // A base under its whole shadow: 0.8 of its size to the nearest 5, from 25 to 80.
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--add-base", "--size", "60"), Sizes(height: "60", base: SizeCard.text(50)))
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--add-base", "--size", "20"), Sizes(height: "20", base: SizeCard.text(25)))
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--add-base", "--size", "200"), Sizes(height: "200", base: SizeCard.text(80)))
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--add-base"), Sizes(height: SizeCard.text(80), base: SizeCard.text(65)))
        XCTAssertEqual(try checked("make", "a", "a teapot", "--object", "--add-base", "--base", "40"), Sizes(height: SizeCard.text(80), base: "40"))
        // A resize keeps what the mini is: an object, though --object wasn't typed.
        let resize = try parse("resize", "a")
        XCTAssertEqual(try resize.checkedSizes(Sizes(height: "60"), object: true), Sizes(height: "60", noBase: true))
        XCTAssertEqual(try resize.checkedSizes(Sizes(height: "60"), object: false), Sizes(height: "60"))
    }

    // MARK: mimic queue

    func testQueueCommands() throws {
        XCTAssertEqual(try QueueCommand.parse([]), .list)
        XCTAssertEqual(try QueueCommand.parse(["pause"]), .pause)
        XCTAssertEqual(try QueueCommand.parse(["resume"]), .resume)
        XCTAssertEqual(try QueueCommand.parse(["move", "Élodie", "--up"]), .move(name: "elodie", .by(-1)))
        XCTAssertEqual(try QueueCommand.parse(["move", "dwarf-cleric", "--down"]), .move(name: "dwarf-cleric", .by(1)))
        XCTAssertEqual(try QueueCommand.parse(["move", "a", "--to", "front"]), .move(name: "a", .to(.front)))
        XCTAssertEqual(try QueueCommand.parse(["move", "a", "--to", "last"]), .move(name: "a", .to(.end)))
        XCTAssertEqual(try QueueCommand.parse(["move", "a", "--to", "3"]), .move(name: "a", .to(.position(3))))
        // The refusal repeats the name as it was typed.
        XCTAssertEqual(try QueueCommand.parse(["remove", "Élodie"]), .remove(name: "elodie", typed: "Élodie"))
    }

    func testQueueRefusals() {
        let move = "usage: mimic queue move <name> --to front|end|<place> | --up | --down"
        for args in [["move"], ["move", "a"], ["move", "a", "--sideways"], ["move", "a", "--to"], ["move", "a", "--to", "0"],
                     ["move", "a", "--to", "middle"], ["move", "a", "--up", "--down"]] {
            XCTAssertEqual(refusal { try QueueCommand.parse(args) }, move, "\(args)")
        }
        for args in [["remove"], ["remove", "a", "b"]] {
            XCTAssertEqual(refusal { try QueueCommand.parse(args) }, "usage: mimic queue remove <name>", "\(args)")
        }
        for args in [["shuffle"], ["pause", "now"], ["resume", "a"]] {
            XCTAssertEqual(refusal { try QueueCommand.parse(args) }, Usage.text, "\(args)")
        }
    }
}
