import XCTest
@testable import MimicCore

/// Ported from tests/test_rename.py.
final class GalleryTests: XCTestCase {
    func testRenameMovesTheFolderAndEveryFileNamedAfterIt() throws {
        let fx = try Fixture(); _ = try fx.mini("dwarf")
        try Gallery.rename(fx.install.runs, from: "dwarf", to: "dwarf-cleric")
        let d = fx.install.runs.appendingPathComponent("dwarf-cleric")
        for f in ["dwarf-cleric.stl", "dwarf-cleric_front.png", "dwarf-cleric_side.png", "dwarf-cleric_back.png", "model.glb", "source.png"] {
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

    func testHiddenAndOrder() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); _ = try fx.mini("_scratch")
        XCTAssertEqual(Gallery.list(fx.install.runs).map(\.name), ["a"])
        XCTAssertEqual(Mini.displayName("tiefling-wizard"), "Tiefling Wizard")
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
