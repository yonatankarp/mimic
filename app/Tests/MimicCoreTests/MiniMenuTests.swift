import XCTest
@testable import MimicCore

/// The one set of rules a mini's menus are built from (#361): the right-click menu, the Mini menu
/// and the toolbar can't disagree about what works when.
final class MiniMenuTests: XCTestCase {
    /// A mini in a fixture's runs folder: with its 3D model unless `model` is false, finished
    /// unless `finished` is false, and made from a description it can be made again from.
    private func mini(_ fx: Fixture, _ name: String, finished: Bool = true, model: Bool = true,
                      settings change: (inout MiniSettings) -> Void = { _ in }) throws -> Mini {
        let folder = fx.install.runs.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if model { try Data().write(to: folder.appendingPathComponent(Mini.modelFile)) }
        var settings = MiniSettings()
        settings.source = .desc
        settings.desc = "a dwarf"
        settings.requested = Sizes(height: "32", base: "25", nozzle: "0.4")
        change(&settings)
        return Mini(name: name, folder: folder, madeAt: Date(), settings: settings, finished: finished)
    }

    /// The queue refuses to resize or rename the mini being made, so the menus don't offer it
    /// (they used to look only at the queue, and the sheet then said no).
    func testResizeRenameAndDuplicateAreOffWhileItsWaitingOrBeingMade() throws {
        let fx = try Fixture()
        let m = try mini(fx, "dwarf")
        for menu in [MiniMenu(making: "dwarf"), MiniMenu(waiting: ["dwarf"])] {
            for action in [MiniAction.resize, .rename, .duplicate] {
                XCTAssertFalse(menu.enabled(action, for: [m]), "\(action) works on a mini that's busy")
            }
        }
        for action in [MiniAction.resize, .rename, .duplicate] {
            XCTAssertTrue(MiniMenu(making: "elf").enabled(action, for: [m]), "\(action) is off while another mini is made")
        }
    }

    /// With a sheet up nothing works, so a shortcut can't swap the sheet for another.
    func testNothingWorksWhileASheetIsUp() throws {
        let fx = try Fixture()
        let a = try mini(fx, "a"), b = try mini(fx, "b")
        let free = MiniMenu(), sheet = MiniMenu(sheetUp: true)
        for action in MiniAction.allCases {
            for minis in [[a], [a, b]] where free.enabled(action, for: minis) {
                XCTAssertFalse(sheet.enabled(action, for: minis), "\(action) works under a sheet")
            }
        }
    }

    func testOpenTogetherNeedsTwoFinishedMinisAndNothingBeingPacked() throws {
        let fx = try Fixture()
        let a = try mini(fx, "a"), b = try mini(fx, "b"), c = try mini(fx, "c", finished: false)
        XCTAssertTrue(MiniMenu().enabled(.openTogether, for: [a, b, c]))
        XCTAssertFalse(MiniMenu().enabled(.openTogether, for: [a, c]), "one finished mini isn't together")
        XCTAssertFalse(MiniMenu(packing: true).enabled(.openTogether, for: [a, b]))
        XCTAssertFalse(MiniMenu(packing: true).enabled(.copies, for: [a]))
        XCTAssertTrue(MiniMenu().enabled(.copies, for: [a, c]))
        XCTAssertFalse(MiniMenu().enabled(.copies, for: [c]))
    }

    /// Open, Export and Rename are for one mini: off with none or several selected.
    func testOneMiniActionsNeedOneMini() throws {
        let fx = try Fixture()
        let a = try mini(fx, "a"), b = try mini(fx, "b"), c = try mini(fx, "c", finished: false)
        for action in [MiniAction.open, .exportForTabletop, .resize, .rename, .anotherVersion, .editAndMakeAgain, .duplicate] {
            XCTAssertTrue(MiniMenu().enabled(action, for: [a]), "\(action)")
            XCTAssertFalse(MiniMenu().enabled(action, for: [a, b]), "\(action) with two")
            XCTAssertFalse(MiniMenu().enabled(action, for: []), "\(action) with none")
        }
        XCTAssertFalse(MiniMenu().enabled(.open, for: [c]), "nothing to print yet")
        XCTAssertFalse(MiniMenu().enabled(.exportForTabletop, for: [c]))
        XCTAssertTrue(MiniMenu().enabled(.rename, for: [c]))
        XCTAssertFalse(MiniMenu().enabled(.showInFinder, for: []))
        XCTAssertFalse(MiniMenu().enabled(.moveToTrash, for: []))
    }

    func testResizeNeedsItsModelAndSetup() throws {
        let fx = try Fixture()
        let a = try mini(fx, "a"), none = try mini(fx, "none", finished: false, model: false)
        XCTAssertFalse(MiniMenu().enabled(.resize, for: [none]))
        XCTAssertFalse(MiniMenu(needsSetup: true).enabled(.resize, for: [a]))
        XCTAssertTrue(MiniMenu().enabled(.resizeSeveral, for: [a, none]))
        XCTAssertFalse(MiniMenu().enabled(.resizeSeveral, for: [none, none]))
        XCTAssertFalse(MiniMenu(needsSetup: true).enabled(.resizeSeveral, for: [a, none]))
        XCTAssertEqual(MiniMenu().title(.resizeSeveral, for: [a, none, a], slicer: "Bambu Studio"), "Resize 3 Minis…")
        XCTAssertEqual(MiniMenu().title(.openTogether, for: [a, none], slicer: "Bambu Studio"), "Open Together in Bambu Studio")
    }

    /// Build Shape, Try Again and Report a Problem are listed only when they apply, and never for
    /// a mini that's waiting or being made.
    func testBuildShapeAndTryAgainShowOnlyWhenTheyApply() throws {
        let fx = try Fixture()
        let made = try mini(fx, "made")
        let failed = try mini(fx, "failed", finished: false) { $0.failed = "It stopped." }
        let imported = try mini(fx, "imported", finished: false) { $0.imported = "x.glb" }
        let check = try mini(fx, "check", finished: false, model: false) { $0.source = .image; $0.checkPicture = true }
        try Data().write(to: check.folder.appendingPathComponent("source.png"))
        let checking = Mini(name: check.name, folder: check.folder, madeAt: Date(), settings: check.settings, finished: false)
        XCTAssertTrue(checking.pictureToCheck)

        let menu = MiniMenu()
        for m in [made, imported, checking] {
            XCTAssertFalse(menu.shows(.tryAgain, for: [m]), m.name)
            XCTAssertFalse(menu.shows(.reportProblem, for: [m]), m.name)
        }
        XCTAssertTrue(menu.shows(.tryAgain, for: [failed]))
        XCTAssertTrue(menu.shows(.reportProblem, for: [failed]))
        XCTAssertTrue(menu.shows(.buildShape, for: [checking]))
        XCTAssertFalse(menu.shows(.buildShape, for: [failed]))
        XCTAssertFalse(menu.shows(.tryAgain, for: [failed, made]), "for one mini")

        XCTAssertFalse(MiniMenu(waiting: ["failed"]).shows(.tryAgain, for: [failed]))
        XCTAssertFalse(MiniMenu(making: "check").shows(.buildShape, for: [checking]))
        XCTAssertFalse(MiniMenu(needsSetup: true).enabled(.tryAgain, for: [failed]))
        XCTAssertTrue(MiniMenu(needsSetup: true).enabled(.reportProblem, for: [failed]), "a report needs nothing set up")
    }

    /// Make Another Version and New 3D Shape need what it was made from; Edit & Make Again opens
    /// New Mini, which works with something not set up but not before Mimic is installed.
    func testMakingAgainNeedsWhatItWasMadeFrom() throws {
        let fx = try Fixture()
        let a = try mini(fx, "a"), imported = try mini(fx, "imported") { $0.requested = nil; $0.imported = "x.glb" }
        for action in [MiniAction.anotherVersion, .newShape, .editAndMakeAgain] {
            XCTAssertFalse(MiniMenu().enabled(action, for: [imported]), "\(action)")
        }
        XCTAssertFalse(MiniMenu().enabled(.newShape, for: [a]), "no picture to keep")
        XCTAssertFalse(MiniMenu(needsSetup: true).enabled(.anotherVersion, for: [a]))
        XCTAssertTrue(MiniMenu(needsSetup: true).enabled(.editAndMakeAgain, for: [a]))
        XCTAssertFalse(MiniMenu(installed: false).enabled(.editAndMakeAgain, for: [a]))
    }
}
