import XCTest
@testable import MimicCore

/// #102: the queue's files on this Mac, out of the minis folder, and choosing another minis folder.
final class MinisFolderTests: XCTestCase {
    let fm = FileManager.default
    let sizes = Sizes(height: "32", nozzle: "0.4")

    /// Another folder beside the fixture's.
    func folder(_ fx: Fixture, _ name: String = "chosen") throws -> URL {
        let d = fx.root.appendingPathComponent(name)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A mini Mimic didn't make here: a folder holding a print file named after it.
    func miniThere(_ folder: URL, _ name: String, in project: String? = nil) throws {
        let d = (project.map { folder.appendingPathComponent($0) } ?? folder).appendingPathComponent(name)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        fm.createFile(atPath: d.appendingPathComponent("\(name).stl").path, contents: Data("stl".utf8))
    }

    func top(_ folder: URL) throws -> [String] { try fm.contentsOfDirectory(atPath: folder.path).sorted() }

    // MARK: The queue's files

    /// Making, pausing and resizing leave nothing at the top of the minis folder but the minis.
    func testAJobWritesNothingInTheMinisFolderButTheMini() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        try jobs.setPaused(true)
        try jobs.resize(name: "a", sizes: sizes)
        try jobs.setPaused(false)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.succeeded, true)
        XCTAssertEqual(try top(fx.install.runs), ["a"])
    }

    // MARK: Choosing another folder

    /// Every mini and project goes. A project moves whole, with files of the person's own; one
    /// whose name is a project's there (without case) puts its minis in that one. Mimic's own
    /// scratch stays behind, and so does the old folder while it holds anything.
    func testMovingTakesEveryMiniAndProject() throws {
        let fx = try Fixture(), runs = fx.install.runs, new = try folder(fx)
        _ = try fx.mini("dwarf")
        _ = try fx.mini("raven", in: "Tiefling Party")
        fm.createFile(atPath: runs.appendingPathComponent("Tiefling Party/notes.txt").path, contents: Data("mine".utf8))
        try fm.createDirectory(at: runs.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        _ = try fx.mini("grunt", in: "Orcs")
        try miniThere(new, "boss", in: "orcs")
        try fm.createDirectory(at: runs.appendingPathComponent("_duplicate-x"), withIntermediateDirectories: true)

        try JobRunner(install: fx.install, tools: fx.tools()).changeMinisFolder(to: new, moving: true)
        XCTAssertEqual(Set(Gallery.list(new).map { "\($0.project ?? "-")/\($0.name)" }),
                       ["-/dwarf", "Tiefling Party/raven", "orcs/grunt", "orcs/boss"])
        XCTAssertEqual(Gallery.projects(new), ["Empty", "orcs", "Tiefling Party"])
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("Tiefling Party/notes.txt").path), "the person's own file was left behind")
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("dwarf/dwarf.stl").path))
        XCTAssertEqual(Gallery.list(runs), [])
        XCTAssertEqual(try top(runs), ["_duplicate-x"], "an emptied project is left, or Mimic's scratch moved")
    }

    /// Names stay unique across the whole folder: when the new one has a mini or project by the
    /// name of one here (without case), nothing moves, and every such name is said.
    func testANameTakenThereMovesNothing() throws {
        let fx = try Fixture(), runs = fx.install.runs, new = try folder(fx)
        _ = try fx.mini("dwarf")
        _ = try fx.mini("raven", in: "Party")
        _ = try fx.mini("elf", in: "Party")
        try fm.createDirectory(at: new.appendingPathComponent("Dwarf"), withIntermediateDirectories: true)
        try miniThere(new, "raven", in: "Birds")

        XCTAssertThrowsError(try JobRunner(install: fx.install, tools: fx.tools()).changeMinisFolder(to: new, moving: true)) {
            XCTAssertEqual($0 as? RequestError, .minisFolderClash(["Dwarf", "Raven"]))
        }
        XCTAssertEqual(Set(Gallery.list(runs).map(\.name)), ["dwarf", "raven", "elf"], "something moved")
        XCTAssertEqual(Set(Gallery.list(new).map(\.name)), ["raven"])
    }

    /// Without moving, the minis stay where they are.
    func testNotMovingLeavesTheMinis() throws {
        let fx = try Fixture(), new = try folder(fx)
        _ = try fx.mini("dwarf")
        try JobRunner(install: fx.install, tools: fx.tools()).changeMinisFolder(to: new, moving: false)
        XCTAssertNotNil(Gallery.folder(fx.install.runs, "dwarf"))
        XCTAssertEqual(try top(new), [])
    }

    /// Refused while a mini waits or is being made, in this Mimic or another using the folder:
    /// a job finds its mini by name in the folder it was asked for in.
    func testRefusedWhileAMiniWaitsOrIsBeingMade() throws {
        let fx = try Fixture(), new = try folder(fx)
        _ = try fx.mini("dwarf")
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        try jobs.queue.locked { $0.append(QueueEntry(name: "dwarf", job: .prep)) }
        XCTAssertThrowsError(try jobs.changeMinisFolder(to: new, moving: true)) { XCTAssertEqual($0 as? RequestError, .minisFolderBusy) }
        try jobs.queue.locked { $0.removeAll() }

        let childFile = fx.root.appendingPathComponent("child.pid").path
        let other = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "echo $$ > \(childFile); sleep 30")))
        try other.resize(name: "dwarf", sizes: sizes)
        for _ in 0..<100 where !fm.fileExists(atPath: childFile) { usleep(50_000) }
        XCTAssertThrowsError(try jobs.changeMinisFolder(to: new, moving: true)) { XCTAssertEqual($0 as? RequestError, .minisFolderBusy) }
        other.cancel(); other.waitUntilDone()
        XCTAssertNotNil(Gallery.folder(fx.install.runs, "dwarf"), "it moved while being made")

        try jobs.changeMinisFolder(to: new, moving: true)
        XCTAssertNotNil(Gallery.folder(new, "dwarf"))
    }

    /// A Make asked for while the minis are moving (here, or `mimic make`) must never land in the
    /// folder they're leaving: refused until the move is done. Many minis, so the move takes long
    /// enough for the Make to be asked in the middle of it.
    func testAMakeDuringAMoveNeverLandsInTheOldFolder() throws {
        let fx = try Fixture(), runs = fx.install.runs, new = try folder(fx)
        try fx.modelFiles()
        let picture = try fx.picture()
        let count = 4000
        for i in 0..<count { try miniThere(runs, "m\(i)") }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(), trash: { _ in })
        try jobs.setPaused(true)  // a Make that gets in isn't run
        let mover = JobRunner(install: fx.install, tools: fx.tools())
        let moved = expectation(description: "moved")
        DispatchQueue.global().async {
            do { try mover.changeMinisFolder(to: new, moving: true) } catch { XCTFail("\(error)") }
            moved.fulfill()
        }
        // Until the first mini has gone: `for … where` would keep listing the folder after that.
        let deadline = Date().addingTimeInterval(30)
        while ((try? fm.contentsOfDirectory(atPath: new.path)) ?? []).isEmpty, Date() < deadline { usleep(1000) }
        XCTAssertFalse(try top(runs).count < count / 2, "the move was over before the Make was asked for")
        var made = false
        do {
            try jobs.make(name: "late", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
            made = true
        } catch {}
        wait(for: [moved], timeout: 120)
        XCTAssertEqual(Gallery.list(new).count, count)
        XCTAssertNil(Gallery.folder(runs, "late"), "a Make during the move went into the folder the minis left")
        if made { XCTAssertNotNil(Gallery.folder(new, "late")) }
    }

    /// The same folder, one inside it, or one holding it: the old folder would turn into a
    /// project of the new, or the new into one of the old.
    func testTheSameOrANestedFolderIsRefused() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fm.createDirectory(at: runs.appendingPathComponent("Party"), withIntermediateDirectories: true)  // chosen folders exist
        XCTAssertThrowsError(try MinisFolder.check(from: runs, to: runs)) { XCTAssertEqual($0 as? RequestError, .sameMinisFolder) }
        XCTAssertThrowsError(try MinisFolder.check(from: runs, to: runs.appendingPathComponent("Party"))) {
            XCTAssertEqual($0 as? RequestError, .minisFolderNested)
        }
        XCTAssertThrowsError(try MinisFolder.check(from: runs, to: fx.root)) { XCTAssertEqual($0 as? RequestError, .minisFolderNested) }
        XCTAssertNoThrow(try MinisFolder.check(from: runs, to: fx.root.appendingPathComponent("runs-2")), "a name that only starts the same")
    }
}
