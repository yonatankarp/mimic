import XCTest
@testable import MimicCore

/// Ported from tests/test_rename.py.
final class GalleryTests: XCTestCase {
    /// A mini's settings are read once, with the list (#95): what the list and its page ask of a
    /// mini afterwards comes from the value, however often a redraw asks. Planted by changing
    /// every file after the list was read: an answer read from disk would see the change.
    func testSettingsAreReadWithTheListNotOnEveryCall() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let made = Sizes(height: "32", base: "25", nozzle: "0.4")
        try MiniSettings.update(try fx.mini("dwarf")) { $0.source = .desc; $0.desc = "a dwarf"; $0.requested = made; $0.made = made }
        for v in ["dwarf-2", "dwarf-3"] { try MiniSettings.update(try fx.mini(v)) { $0.versionOf = "dwarf"; $0.made = made } }
        let minis = Gallery.list(runs), dwarf = minis.first { $0.name == "dwarf" }!
        for m in minis { try Data("{}".utf8).write(to: m.folder.appendingPathComponent("settings.json")) }
        XCTAssertEqual(dwarf.settings.made, made)
        XCTAssertEqual(Gallery.versions(of: dwarf, in: minis).map(\.name), ["dwarf", "dwarf-2", "dwarf-3"])
        XCTAssertTrue(JobRunner.canMakeAnotherVersion(dwarf))
        XCTAssertEqual(Gallery.toResize(minis, to: made, busy: []).same, 3)
        XCTAssertNil(Gallery.list(runs).first { $0.name == "dwarf" }!.settings.made, "a reload reads them again")
    }

    /// A reload notices settings that changed while the files it's named by didn't: a run that
    /// failed, or a rename that moved its versions to a new first one. Otherwise the list, which
    /// only takes a new list that differs, would go on showing the old ones.
    func testAReloadNoticesChangedSettings() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let folder = try fx.mini("dwarf")
        let before = Gallery.list(runs)
        try MiniSettings.update(folder) { $0.failed = "It stopped while drawing it." }
        let after = Gallery.list(runs)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.first?.settings.failed, "It stopped while drawing it.")
    }

    /// A mini shows the name it was given (#87), from its settings as the list read them; an
    /// older mini without one shows its folder's as before. Planted: a name rebuilt from the
    /// folder says "Elodie", "D D Bard" and "Mcgregor".
    func testAMiniShowsTheNameItWasGiven() throws {
        let fx = try Fixture(), runs = fx.install.runs
        for (typed, folder) in [("Élodie", "elodie"), ("D&D Bard", "d-d-bard"), ("McGregor", "mcgregor"), ("Дракон", "drakon")] {
            XCTAssertEqual(Rules.folderName(typed), folder)
            try MiniSettings.update(try fx.mini(folder)) { $0.name(typed, folder: folder) }
        }
        _ = try fx.mini("tiefling-wizard")
        let minis = Gallery.list(runs)
        XCTAssertEqual(Mini.displayName("elodie", runs: runs), "Élodie")
        for m in minis { try Data("{}".utf8).write(to: m.folder.appendingPathComponent("settings.json")) }
        XCTAssertEqual(Set(minis.map(\.displayName)), ["Élodie", "D&D Bard", "McGregor", "Дракон", "Tiefling Wizard"])
        XCTAssertEqual(Mini.displayName("mcgregor", in: minis), "McGregor")
        XCTAssertEqual(Mini.displayName("ghost-king", in: minis), "Ghost King", "not in the list")
    }

    /// Rename keeps the name as typed, when only its capitals change too. Renamed without one
    /// (the kept version taking the plain name, and its Undo), the name it had comes along
    /// while it fits; an older mini gets no settings for a rename.
    func testRenameKeepsTheTypedName() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try MiniSettings.update(try fx.mini("mcgregor")) { $0.name("Mcgregor", folder: "mcgregor") }
        try Gallery.rename(runs, from: "mcgregor", to: "mcgregor", shown: "McGregor")
        XCTAssertEqual(Gallery.list(runs).map(\.displayName), ["McGregor"], "only the capitals changed")
        try Gallery.rename(runs, from: "mcgregor", to: Rules.folderName("Élodie"), shown: "Élodie")
        XCTAssertEqual(Gallery.list(runs).map(\.displayName), ["Élodie"])
        try Gallery.rename(runs, from: "elodie", to: "elodie-2")
        XCTAssertEqual(Gallery.list(runs).map(\.displayName), ["Élodie 2"])
        try Gallery.rename(runs, from: "elodie-2", to: "elodie")
        XCTAssertEqual(Gallery.list(runs).map(\.displayName), ["Élodie"])
        try Gallery.rename(runs, from: "elodie", to: "orc")
        XCTAssertEqual(Gallery.list(runs).map(\.displayName), ["Orc"], "a name that doesn't fit is let go")
        _ = try fx.mini("tiefling")  // model.glb and no settings.json
        try Gallery.rename(runs, from: "tiefling", to: "tiefling-wizard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runs.appendingPathComponent("tiefling-wizard/settings.json").path))
        XCTAssertThrowsError(try Gallery.rename(runs, from: "orc", to: "orc", shown: "ORC", busyWith: "orc")) {
            XCTAssertEqual($0 as? RequestError, .busy("orc"))
        }
    }

    /// Keep This One asks "Call it …?" with the name the rename then gives it (#128). Planted:
    /// the name rebuilt from the folder says "Elodie".
    func testAskingToRenameShowsTheNameItGets() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try MiniSettings.update(try fx.mini("elodie-2")) { $0.name("Élodie 2", folder: "elodie-2") }
        _ = try fx.mini("orc-2")  // an older mini, with no name of its own
        let minis = Gallery.list(runs)
        let elodie = try XCTUnwrap(minis.first { $0.name == "elodie-2" })
        XCTAssertEqual(elodie.displayName(renamedTo: "elodie"), "Élodie")
        XCTAssertEqual(try XCTUnwrap(minis.first { $0.name == "orc-2" }).displayName(renamedTo: "orc"), "Orc")
        try Gallery.rename(runs, from: "elodie-2", to: "elodie")
        XCTAssertEqual(Gallery.list(runs).first { $0.name == "elodie" }?.displayName, elodie.displayName(renamedTo: "elodie"))
    }

    /// Finder wins (#87): a mini renamed there shows its folder's new name, a copy doesn't pass
    /// for the original, and a name typed there with capitals or accents is kept as typed. An
    /// unfinished one (no print file, so never taken over) goes by its folder too.
    func testANameGivenInFinderWins() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        for (typed, folder) in [("Élodie", "elodie"), ("Raven", "raven"), ("Bard", "bard")] {
            try MiniSettings.update(try fx.mini(folder)) { $0.name(typed, folder: folder) }
        }
        let gnome = runs.appendingPathComponent("gnome")
        try fm.createDirectory(at: gnome, withIntermediateDirectories: true)
        try MiniSettings.update(gnome) { $0.name("Gnome", folder: "gnome") }
        try fm.moveItem(at: runs.appendingPathComponent("elodie"), to: runs.appendingPathComponent("Élodie la Druide"))
        try fm.copyItem(at: runs.appendingPathComponent("raven"), to: runs.appendingPathComponent("raven copy"))
        try fm.moveItem(at: runs.appendingPathComponent("bard"), to: runs.appendingPathComponent("bard-king"))
        try fm.moveItem(at: gnome, to: runs.appendingPathComponent("gnome-king"))
        Gallery.adopt(runs, busy: [])
        let shown = Dictionary(uniqueKeysWithValues: Gallery.list(runs).map { ($0.name, $0.displayName) })
        XCTAssertEqual(shown, ["elodie-la-druide": "Élodie la Druide", "raven": "Raven", "raven-copy": "Raven Copy",
                               "bard-king": "Bard King", "gnome-king": "Gnome King"])
    }

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

    /// A resize makes a new print file; the list goes by when each mini was asked for, so it
    /// stays where it was (#75). A mini from before that date was saved goes by its folder's.
    func testAResizeKeepsTheMinisPlace() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        let day: TimeInterval = 86400
        let old = try fx.mini("old")
        try fm.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3 * day)], ofItemAtPath: old.path)
        for (name, days) in [("dwarf", 2.0), ("elf", 1.0)] {
            try MiniSettings.update(try fx.mini(name)) { $0.created = Date(timeIntervalSinceNow: -days * day) }
        }
        let sizes = Sizes(height: "100", base: "40", nozzle: "0.4")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", #"touch "$3""#)))
        for name in ["dwarf", "old"] {
            try jobs.resize(name: name, sizes: sizes)
            jobs.waitUntilDone()
            XCTAssertEqual(jobs.status?.succeeded, true, name)
        }
        XCTAssertEqual(Gallery.list(runs).map(\.name), ["elf", "dwarf", "old"], "a resize moved a mini")
        let dwarf = MiniSettings.load(runs.appendingPathComponent("dwarf"))
        XCTAssertEqual(dwarf.made, sizes)
        XCTAssertEqual(try XCTUnwrap(dwarf.created).timeIntervalSinceNow, -2 * day, accuracy: 60, "a resize changed when it was asked for")
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

        // One Mimic couldn't take over (#74) still goes, by the folder the gallery found.
        let odd = fx.install.runs.appendingPathComponent("Dwarf Cleric")
        try FileManager.default.moveItem(at: try fx.mini("dwarf-cleric"), to: odd)
        try Gallery.moveToTrash(fx.install.runs, name: "Dwarf Cleric", folder: odd, trash: { spy($0) })
        XCTAssertEqual(spy.trashed.last, odd)
    }

    /// Minis renamed or copied in Finder (#74) get a name Mimic can use, and their files follow.
    func testAFolderRenamedOrCopiedInFinderIsTakenOver() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        try fm.moveItem(at: try fx.mini("dwarf-cleric"), to: runs.appendingPathComponent("Dwarf Cleric"))
        try fm.copyItem(at: try fx.mini("raven"), to: runs.appendingPathComponent("raven copy"))
        try fm.moveItem(at: try fx.mini("elf"), to: runs.appendingPathComponent("Elf"))  // only the capitals
        try fm.moveItem(at: try fx.mini("bard"), to: runs.appendingPathComponent("bard-king"))  // a good name, files not
        XCTAssertEqual(Set(Gallery.adopt(runs, busy: [])), ["dwarf-cleric", "raven-copy", "elf", "bard-king"])
        for name in ["dwarf-cleric", "raven-copy", "elf", "bard-king", "raven"] {
            for suffix in [".stl", "_front.png", "_left.png", "_right.png", "_back.png"] {
                XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("\(name)/\(name)\(suffix)").path), name + suffix)
            }
        }
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: runs.path)), ["dwarf-cleric", "raven-copy", "elf", "bard-king", "raven"])
        XCTAssertTrue(Gallery.list(runs).allSatisfy { $0.stl != nil && Gallery.folder(runs, $0.name) == $0.folder })
        XCTAssertEqual(Gallery.adopt(runs, busy: []), [], "took over a mini that was fine")
    }

    /// Taking over never moves anything over a mini or folder already there: the name taken
    /// anywhere (here in another project), or by a folder that isn't a mini, gets the next one.
    func testTakingOverNeverOverwrites() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        _ = try Gallery.createProject(runs, "Party")
        let kept = try fx.mini("dwarf-cleric")
        try "keep me".write(to: kept.appendingPathComponent("dwarf-cleric.stl"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: kept, to: runs.appendingPathComponent("Party/dwarf-cleric"))
        try fm.moveItem(at: try fx.mini("dwarf-cleric"), to: runs.appendingPathComponent("Dwarf Cleric"))
        let plain = runs.appendingPathComponent("Party/raven-copy")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try "mine".write(to: plain.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try fm.copyItem(at: try fx.mini("raven"), to: runs.appendingPathComponent("Party/raven copy"))

        XCTAssertEqual(Set(Gallery.adopt(runs, busy: [])), ["dwarf-cleric-2", "raven-copy-2"])
        XCTAssertEqual(try String(contentsOf: runs.appendingPathComponent("Party/dwarf-cleric/dwarf-cleric.stl"), encoding: .utf8), "keep me")
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("dwarf-cleric-2/dwarf-cleric-2.stl").path))
        XCTAssertFalse(fm.fileExists(atPath: runs.appendingPathComponent("dwarf-cleric").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: plain.path), ["notes.txt"])
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("Party/raven-copy-2/raven-copy-2.stl").path))
    }

    /// A mini being made or waiting is left as it is: its job finds it by name.
    func testTakingOverLeavesAMiniBeingMadeOrWaitingAlone() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        try fm.moveItem(at: try fx.mini("dwarf"), to: runs.appendingPathComponent("dwarf-king"))
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        try jobs.queue.locked { $0.append(QueueEntry(name: "dwarf-king", job: .prep)) }
        XCTAssertEqual(jobs.adoptOddFolders(), [])
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("dwarf-king/dwarf.stl").path), "renamed a waiting mini's files")
        try jobs.queue.locked { $0.removeAll() }
        XCTAssertEqual(jobs.adoptOddFolders(), ["dwarf-king"])
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("dwarf-king/dwarf-king.stl").path))
    }

    /// The list just read is looked at for minis to take over, not the folder read again.
    func testTakingOverLooksAtTheListGiven() throws {
        let fx = try Fixture(), fm = FileManager.default, runs = fx.install.runs
        try fm.moveItem(at: try fx.mini("dwarf"), to: runs.appendingPathComponent("dwarf-king"))
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        XCTAssertEqual(jobs.adoptOddFolders(listed: []), [], "nothing listed to take over")
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("dwarf-king/dwarf.stl").path))
        XCTAssertEqual(jobs.adoptOddFolders(listed: Gallery.list(runs)), ["dwarf-king"])
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("dwarf-king/dwarf-king.stl").path))
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
        XCTAssertEqual(previews.map(\.caption), ["Picture", "Front", "Left", "Right", "Back"])
        XCTAssertEqual(previews.step(from: previews[0], by: 1)?.caption, "Front")
        XCTAssertEqual(previews.step(from: previews[3], by: -1)?.caption, "Left")
        XCTAssertNil(previews.step(from: previews[0], by: -1), "wrapped round from the first")
        XCTAssertNil(previews.step(from: previews[4], by: 1), "wrapped round from the last")
        // ← → cross the rows: Left is the end of the first row of views, Front the start.
        XCTAssertEqual(previews.step(from: previews[2], by: 1)?.caption, "Right")
        XCTAssertEqual(previews.step(from: previews[1], by: -1)?.caption, "Picture")

        // ↑ ↓: the picture full width, Front Left over Right Back.
        func vertical(_ p: [MiniPreview], wide: Int) -> [String] {
            p.flatMap { from in [-1, 1].map { p.step(from: from, down: $0, wide: wide)?.caption ?? "-" } }
        }
        XCTAssertEqual(vertical(previews, wide: 1), [
            "-", "Front",             // Picture
            "Picture", "Right",  // Front
            "Picture", "Back",   // Left
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
        let withPicture = [MiniPreview(caption: "Picture", url: d)] + mini.previews
        XCTAssertEqual(vertical(withPicture, wide: 1), ["-", "Front", "Picture", "Back", "Picture", "-", "Front", "-"])
    }

    /// `mimic list` printed "2026-09-30 16:23:01 +0000". Time zones are given, so this passes
    /// wherever it runs.
    func testListDatesAreLocalAndReadable() throws {
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")), tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let made = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T16:23:01Z"))
        let soon = made.addingTimeInterval(3600)
        XCTAssertEqual(Mini.listDate(made, now: soon, timeZone: berlin), "30 Sep, 18:23")
        XCTAssertEqual(Mini.listDate(made, now: soon, timeZone: tokyo), "1 Oct, 01:23")
        XCTAssertEqual(Mini.listDate(made, now: made.addingTimeInterval(200 * 86400), timeZone: berlin), "30 Sep 2026, 18:23",
                       "another year says which")
        // New Year's Eve in London is already New Year's Day in Berlin: the year is the local one.
        let eve = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-12-31T23:30:00Z"))
        let newYear = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z"))
        XCTAssertEqual(Mini.listDate(eve, now: newYear, timeZone: berlin), "1 Jan, 00:30")
        XCTAssertEqual(Mini.listDate(eve, now: newYear, timeZone: utc), "31 Dec 2025, 23:30")
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
