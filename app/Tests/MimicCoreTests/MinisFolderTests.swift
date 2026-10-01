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

    /// A Mimic from before #102 kept the queue at the top of the minis folder. The first launch
    /// after moves it: the waiting jobs join any already here (none twice), the pause and a
    /// running program's record come along, and nothing of the queue's is left in the minis
    /// folder. Launching again changes nothing.
    func testTheQueueFilesMoveOutOfTheMinisFolderOnce() throws {
        let fx = try Fixture(), runs = fx.install.runs, queue = JobQueue(folder: fx.install.queue)
        try queue.locked { $0 = [QueueEntry(name: "here", job: .prep)] }
        let before = [QueueEntry(name: "a", job: .generate), QueueEntry(name: "here", job: .generate),
                      QueueEntry(name: "b", job: .prep, sizes: sizes)]
        try JobQueue.encoder.encode(before).write(to: runs.appendingPathComponent(".queue.json"))
        for f in [".queue.paused", ".queue.lock", ".job.lock", ".job.json"] {
            fm.createFile(atPath: runs.appendingPathComponent(f).path, contents: nil)
        }
        try "123 456".write(to: runs.appendingPathComponent(".job.pid"), atomically: true, encoding: .utf8)

        try queue.moveOldFiles(from: runs)
        XCTAssertEqual(queue.entries().map(\.name), ["here", "a", "b"])
        XCTAssertEqual(queue.entries().first?.job, .prep, "the one already here was replaced")
        XCTAssertEqual(queue.entries().last?.sizes, sizes)
        XCTAssertTrue(queue.paused, "the pause was lost")
        XCTAssertEqual(try String(contentsOf: Leftover.file(queue: fx.install.queue), encoding: .utf8), "123 456")
        XCTAssertEqual(try top(runs), [], "the queue's files are still in the minis folder")

        try queue.moveOldFiles(from: runs)
        XCTAssertEqual(queue.entries().map(\.name), ["here", "a", "b"])
    }

    /// A running program's record already here is the one to keep: the old one is dropped.
    func testTheMoveNeverOverwrites() throws {
        let fx = try Fixture(), runs = fx.install.runs, queue = JobQueue(folder: fx.install.queue)
        try "1 2".write(to: Leftover.file(queue: fx.install.queue), atomically: true, encoding: .utf8)
        try "3 4".write(to: runs.appendingPathComponent(".job.pid"), atomically: true, encoding: .utf8)
        try queue.moveOldFiles(from: runs)
        XCTAssertEqual(try String(contentsOf: Leftover.file(queue: fx.install.queue), encoding: .utf8), "1 2")
        XCTAssertEqual(try top(runs), [])
    }

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

    /// The same folder, one inside it, or one holding it: the old folder would turn into a
    /// project of the new, or the new into one of the old.
    func testTheSameOrANestedFolderIsRefused() throws {
        let fx = try Fixture(), runs = fx.install.runs
        XCTAssertThrowsError(try MinisFolder.check(from: runs, to: runs)) { XCTAssertEqual($0 as? RequestError, .sameMinisFolder) }
        XCTAssertThrowsError(try MinisFolder.check(from: runs, to: runs.appendingPathComponent("Party"))) {
            XCTAssertEqual($0 as? RequestError, .minisFolderNested)
        }
        XCTAssertThrowsError(try MinisFolder.check(from: runs, to: fx.root)) { XCTAssertEqual($0 as? RequestError, .minisFolderNested) }
        XCTAssertNoThrow(try MinisFolder.check(from: runs, to: fx.root.appendingPathComponent("runs-2")), "a name that only starts the same")
    }
}
