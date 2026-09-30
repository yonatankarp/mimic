import XCTest
@testable import MimicCore

/// Ported from tests/test_rename.py.
final class GalleryTests: XCTestCase {
    func testRenameMovesTheFolderAndEveryFileNamedAfterIt() throws {
        let fx = try Fixture(); _ = try fx.mini("dwarf")
        try Gallery.rename(fx.install.runs, from: "dwarf", to: "dwarf-cleric")
        let d = fx.install.runs.appendingPathComponent("dwarf-cleric")
        for f in ["dwarf-cleric.stl", "dwarf-cleric_front.png", "dwarf-cleric_left.png", "dwarf-cleric_right.png", "dwarf-cleric_back.png", "model.glb", "source.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent(f).path), f)
        }
        XCTAssertEqual(Gallery.list(fx.install.runs).first?.stl?.lastPathComponent, "dwarf-cleric.stl")
    }

    func testARenameKeepsTheMinisDateAndPlace() throws {
        let fx = try Fixture(); let d = try fx.mini("dwarf")
        let old = Date(timeIntervalSinceNow: -3 * 86400)
        for f in try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path)
        }
        _ = try fx.mini("newer")
        try Gallery.rename(fx.install.runs, from: "dwarf", to: "dwarf-cleric")
        let list = Gallery.list(fx.install.runs)
        XCTAssertEqual(list.map(\.name), ["newer", "dwarf-cleric"], "a rename moved it to the top")
        XCTAssertEqual(list[1].madeAt.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 2)
    }

    func testRenameRefusals() throws {
        let fx = try Fixture(); _ = try fx.mini("dwarf"); _ = try fx.mini("taken")
        XCTAssertThrowsError(try Gallery.rename(fx.install.runs, from: "dwarf", to: "taken")) { XCTAssertEqual($0 as? RequestError, .nameTaken("taken")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("dwarf/dwarf.stl").path), "a refused rename moved files")
        XCTAssertThrowsError(try Gallery.rename(fx.install.runs, from: "dwarf", to: "other", busyWith: "dwarf")) { XCTAssertEqual($0 as? RequestError, .busy("dwarf")) }
        XCTAssertThrowsError(try Gallery.rename(fx.install.runs, from: "ghost", to: "x")) { XCTAssertEqual($0 as? RequestError, .notFound) }
        XCTAssertThrowsError(try Gallery.rename(fx.install.runs, from: "dwarf", to: "../x")) { XCTAssertEqual($0 as? RequestError, .badName) }
    }

    func testMoveToTrash() throws {
        let fx = try Fixture(); _ = try fx.mini("dwarf")
        let spy = TrashSpy()
        try Gallery.moveToTrash(fx.install.runs, name: "dwarf", trash: { spy($0) })
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["dwarf"])
        XCTAssertThrowsError(try Gallery.moveToTrash(fx.install.runs, name: "dwarf", busyWith: "dwarf", trash: { spy($0) }))
    }

    /// Undo for Move to Trash, with a folder standing in for the Trash.
    func testPutBackFromTheTrash() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        let bin = fx.root.appendingPathComponent("Trash")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func toBin(_ u: URL) throws -> URL? {
            let to = bin.appendingPathComponent(u.lastPathComponent)
            try fm.moveItem(at: u, to: to)
            return to
        }
        _ = try Gallery.createProject(runs, "Party")
        try fm.moveItem(at: try fx.mini("dwarf"), to: runs.appendingPathComponent("Party/dwarf"))
        let (folder, trashed) = try Gallery.moveToTrash(runs, name: "dwarf", trash: toBin)
        XCTAssertNil(Gallery.folder(runs, "dwarf"))
        try Gallery.putBack(runs, from: XCTUnwrap(trashed), to: folder)
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("Party/dwarf/dwarf.stl").path), "not back in its project")

        // Its project deleted meanwhile: made again.
        let again = try Gallery.moveToTrash(runs, name: "dwarf", trash: toBin)
        try fm.removeItem(at: runs.appendingPathComponent("Party"))
        try Gallery.putBack(runs, from: XCTUnwrap(again.trashed), to: again.folder)
        XCTAssertEqual(Gallery.list(runs).map(\.project), ["Party"])

        // Its name taken meanwhile: left in the Trash.
        let third = try Gallery.moveToTrash(runs, name: "dwarf", trash: toBin)
        _ = try fx.mini("dwarf")
        XCTAssertThrowsError(try Gallery.putBack(runs, from: XCTUnwrap(third.trashed), to: third.folder)) {
            XCTAssertEqual($0 as? RequestError, .nameTaken("dwarf"))
        }
        XCTAssertTrue(fm.fileExists(atPath: bin.appendingPathComponent("dwarf").path))
    }

    func testHiddenAndOrder() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); _ = try fx.mini("_scratch")
        XCTAssertEqual(Gallery.list(fx.install.runs).map(\.name), ["a"])
        XCTAssertEqual(Mini.displayName("tiefling-wizard"), "Tiefling Wizard")
    }

    /// The page's previews and ← →: only the ones it has, in order, stopping at both ends. A mini
    /// made before the left and right views shows its one side view.
    func testPreviewsInOrderAndStepping() throws {
        let fx = try Fixture(), d = try fx.mini("dwarf")
        var mini = Gallery.list(fx.install.runs)[0]
        let previews = mini.previews
        XCTAssertEqual(previews.map(\.caption), ["Your picture", "Front", "Left", "Right", "Back"])
        XCTAssertEqual(previews.step(from: previews[0], by: 1)?.caption, "Front")
        XCTAssertEqual(previews.step(from: previews[3], by: -1)?.caption, "Left")
        XCTAssertNil(previews.step(from: previews[0], by: -1), "wrapped round from the first")
        XCTAssertNil(previews.step(from: previews[4], by: 1), "wrapped round from the last")
        // ← → cross the rows: Left is the end of the first row of views, Front the start.
        XCTAssertEqual(previews.step(from: previews[2], by: 1)?.caption, "Right")
        XCTAssertEqual(previews.step(from: previews[1], by: -1)?.caption, "Your picture")

        // ↑ ↓: the picture full width, Front Left over Right Back.
        func vertical(_ p: [MiniPreview], wide: Int) -> [String] {
            p.flatMap { from in [-1, 1].map { p.step(from: from, down: $0, wide: wide)?.caption ?? "-" } }
        }
        XCTAssertEqual(vertical(previews, wide: 1), [
            "-", "Front",             // Your picture
            "Your picture", "Right",  // Front
            "Your picture", "Back",   // Left
            "Front", "-",             // Right
            "Left", "-",              // Back
        ])

        let fm = FileManager.default
        try fm.removeItem(at: d.appendingPathComponent("dwarf_left.png"))
        try fm.removeItem(at: d.appendingPathComponent("dwarf_right.png"))
        try fm.removeItem(at: d.appendingPathComponent("source.png"))
        fm.createFile(atPath: d.appendingPathComponent("dwarf_side.png").path, contents: Data([1]))
        mini = Gallery.list(fx.install.runs)[0]
        XCTAssertEqual(mini.previews.map(\.caption), ["Front", "Side", "Back"])
        XCTAssertEqual(vertical(mini.previews, wide: 0), ["-", "Back", "-", "-", "Front", "-"])
        XCTAssertEqual(mini.previews.step(from: mini.previews[1], by: 1)?.caption, "Back")
        let withPicture = [MiniPreview(caption: "Your picture", url: d)] + mini.previews
        XCTAssertEqual(vertical(withPicture, wide: 1), ["-", "Front", "Your picture", "Back", "Your picture", "-", "Front", "-"])
    }
}

final class SlicerTests: XCTestCase {
    func testFindsInstalledSlicersAndHonoursThePick() throws {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for b in ["OrcaSlicer.app", "BambuStudio.app"] {
            try FileManager.default.createDirectory(at: apps.appendingPathComponent(b), withIntermediateDirectories: true)
        }
        XCTAssertEqual(Slicer.installed(in: [apps]).map(\.id), ["bambu", "orca"])
        let d = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(Slicer.preferred(defaults: d, in: [apps])?.id, "bambu", "the first installed when none is picked")
        d.set("orca", forKey: "slicer")
        XCTAssertEqual(Slicer.preferred(defaults: d, in: [apps])?.id, "orca")
        d.set("cura", forKey: "slicer")
        XCTAssertEqual(Slicer.preferred(defaults: d, in: [apps])?.id, "bambu", "a picked slicer that's gone falls back")
        XCTAssertNil(Slicer.preferred(defaults: d, in: [apps.appendingPathComponent("none")]))
    }
}
