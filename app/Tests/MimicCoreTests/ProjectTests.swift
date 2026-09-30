import XCTest
@testable import MimicCore

extension Fixture {
    /// A finished mini inside `project`.
    func mini(_ name: String, in project: String) throws -> URL {
        let top = try mini(name)
        let d = install.runs.appendingPathComponent(project).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: top, to: d)
        return d
    }

    /// Print prep that notes the print file it was asked for (its path says which folder).
    func recorder(sleep: Double = 0) throws -> String {
        try script("prep", "echo \"$3\" >> \"\(root.path)/ran.txt\"; sleep \(sleep)")
    }
}

/// Projects (folders of minis) and Make Another Version.
final class ProjectTests: XCTestCase {
    let sizes = Sizes(height: "32", nozzle: "0.4")
    let fm = FileManager.default

    func ran(_ fx: Fixture) -> [String] {
        ((try? String(contentsOf: fx.root.appendingPathComponent("ran.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: Layout

    /// Flat minis, projects, hidden folders and Mimic's own files, side by side, as a folder
    /// from before projects looks with one added.
    func testLayoutWithProjectsAndFlatMinisTogether() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("dwarf-cleric")
        // An old mini with no settings.json (the live folder has one): its model.glb says what it is.
        let sculpt = runs.appendingPathComponent("tiefling-sculpt")
        try fm.createDirectory(at: sculpt, withIntermediateDirectories: true)
        fm.createFile(atPath: sculpt.appendingPathComponent("model.glb").path, contents: Data([1]))
        // A mini asked for a moment ago: only settings.json and its picture so far.
        let queued = runs.appendingPathComponent("Tiefling Party/raven")
        try fm.createDirectory(at: queued, withIntermediateDirectories: true)
        try MiniSettings.update(queued) { $0.source = .image }
        _ = try fx.mini("wizard", in: "Tiefling Party")
        try fm.createDirectory(at: runs.appendingPathComponent("Empty One"), withIntermediateDirectories: true)
        // A project someone put their own files in: an .stl and a folder that aren't minis.
        try fm.createDirectory(at: runs.appendingPathComponent("Props/notes"), withIntermediateDirectories: true)
        fm.createFile(atPath: runs.appendingPathComponent("Props/downloaded.stl").path, contents: Data([1]))
        _ = try fx.mini("chest", in: "Props")
        for hidden in ["_dist-check", ".inflight", "Props/_scratch"] {
            try fm.createDirectory(at: runs.appendingPathComponent(hidden), withIntermediateDirectories: true)
            fm.createFile(atPath: runs.appendingPathComponent(hidden).appendingPathComponent("model.glb").path, contents: Data([1]))
        }
        for f in [".queue.json", ".job.lock", ".job.pid", "tiefling-sculpt.png"] { fm.createFile(atPath: runs.appendingPathComponent(f).path, contents: Data("[]".utf8)) }

        let list = Gallery.list(runs)
        XCTAssertEqual(Set(list.map(\.name)), ["dwarf-cleric", "tiefling-sculpt", "raven", "wizard", "chest"])
        XCTAssertEqual(Gallery.projects(runs), ["Empty One", "Props", "Tiefling Party"])
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        XCTAssertNil(byName["dwarf-cleric"]?.project)
        XCTAssertEqual(byName["raven"]?.project, "Tiefling Party")
        XCTAssertEqual(byName["chest"]?.project, "Props")
        XCTAssertEqual(Gallery.folder(runs, "wizard")?.path, runs.appendingPathComponent("Tiefling Party/wizard").path)
        XCTAssertEqual(Gallery.folder(runs, "dwarf-cleric")?.path, runs.appendingPathComponent("dwarf-cleric").path)
        XCTAssertNil(Gallery.folder(runs, "notes"), "a project's own folder isn't a mini")
        XCTAssertNil(Gallery.folder(runs, "ghost"))
    }

    /// On a Mac's disk "Orcs" and "orcs" are one folder: a project isn't found as a mini, and the
    /// one name can't be both.
    func testNamesAreUniqueAcrossProjects() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles()
        _ = try fx.mini("raven", in: "Tiefling Party")
        _ = try fx.mini("dwarf")
        try Gallery.createProject(runs, "Orcs")
        XCTAssertNil(Gallery.folder(runs, "orcs"))
        XCTAssertTrue(Gallery.nameInUse(runs, "orcs"))
        XCTAssertTrue(Gallery.nameInUse(runs, "raven"))
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        let picture = fx.root.appendingPathComponent("pic.png"); fm.createFile(atPath: picture.path, contents: Data([1]))
        for (name, project) in [("raven", nil), ("raven", "Orcs"), ("dwarf", "Orcs"), ("orcs", nil)] as [(String, String?)] {
            XCTAssertThrowsError(try jobs.make(name: name, picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                               model: EngineDownload.standard, project: project), "\(name) in \(project ?? "Unsorted")") {
                XCTAssertEqual($0 as? RequestError, .nameTaken(name))
            }
        }
        XCTAssertThrowsError(try Gallery.rename(runs, from: "dwarf", to: "raven")) { XCTAssertEqual($0 as? RequestError, .nameTaken("raven")) }
        XCTAssertThrowsError(try Gallery.rename(runs, from: "dwarf", to: "orcs")) { XCTAssertEqual($0 as? RequestError, .nameTaken("orcs")) }
        XCTAssertThrowsError(try Gallery.createProject(runs, "Raven")) { XCTAssertEqual($0 as? RequestError, .projectTaken("Raven")) }
        XCTAssertThrowsError(try Gallery.createProject(runs, "orcs")) { XCTAssertEqual($0 as? RequestError, .projectTaken("orcs")) }
        for bad in ["", "  ", "_mine", ".hidden", "a/b", "a:b"] {
            XCTAssertThrowsError(try Gallery.createProject(runs, bad), bad) { XCTAssertEqual($0 as? RequestError, .badProjectName) }
        }
        XCTAssertEqual(Gallery.project(runs, named: "tiefling party"), "Tiefling Party")
        XCTAssertEqual(Set(Gallery.list(runs).map(\.name)), ["raven", "dwarf"], "a refusal wrote something")
    }

    // MARK: Everything that names a mini finds it in its project

    func testResizeRetryRenameTrashAndEstimatesFindAMiniInAProject() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let d = try fx.mini("raven", in: "Tiefling Party")
        try MiniSettings.update(d) { $0.requested = self.sizes; $0.kind = .object }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder()))
        try jobs.resize(name: "raven", sizes: sizes)
        jobs.waitUntilDone()
        try jobs.retry(name: "raven")  // has a model: a resize
        jobs.waitUntilDone()
        XCTAssertEqual(ran(fx), [d.appendingPathComponent("raven.stl").path, d.appendingPathComponent("raven.stl").path])
        XCTAssertEqual(MiniSettings.load(d).made, sizes, "the finished job wrote its sizes elsewhere")
        XCTAssertEqual(jobs.estimate("raven", .generate, history: []).total,
                       Estimator.estimate(JobShape(.generate, settings: MiniSettings.load(d), sizes: nil), history: []).total)

        try Gallery.rename(runs, from: "raven", to: "raven-familiar")
        let renamed = runs.appendingPathComponent("Tiefling Party/raven-familiar")
        XCTAssertTrue(fm.fileExists(atPath: renamed.appendingPathComponent("raven-familiar.stl").path), "a rename left its project")
        let spy = TrashSpy()
        try Gallery.moveToTrash(runs, name: "raven-familiar", trash: { spy($0) })
        XCTAssertEqual(spy.trashed.map(\.path), [renamed.path])
    }

    /// A new mini asked for into a project is written there, waits there, is made there, and
    /// taking it out of the queue trashes that folder.
    func testTheQueueWritesANewMiniIntoItsProject() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles()
        _ = try fx.mini("first")
        try Gallery.createProject(runs, "Tiefling Party")
        let picture = fx.root.appendingPathComponent("pic.png"); fm.createFile(atPath: picture.path, contents: Data([1]))
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 0.5)), trash: { spy($0) })
        try jobs.resize(name: "first", sizes: sizes)
        for n in ["raven", "owl"] {
            XCTAssertNotNil(try jobs.make(name: n, picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                          model: EngineDownload.standard, project: "Tiefling Party"))
        }
        let raven = runs.appendingPathComponent("Tiefling Party/raven")
        XCTAssertTrue(fm.fileExists(atPath: raven.appendingPathComponent("upload.img").path))
        XCTAssertFalse(fm.fileExists(atPath: runs.appendingPathComponent("raven").path))
        XCTAssertEqual(Gallery.list(runs).first { $0.name == "raven" }?.project, "Tiefling Party")
        XCTAssertTrue(try jobs.remove("owl"))
        XCTAssertEqual(spy.trashed.map(\.path), [runs.appendingPathComponent("Tiefling Party/owl").path])
        XCTAssertThrowsError(try jobs.make(name: "x", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard, project: "Nope")) { XCTAssertEqual($0 as? RequestError, .projectNotFound) }
        jobs.waitUntilDone()
        XCTAssertEqual(ran(fx).last, raven.appendingPathComponent("raven.stl").path, "made outside its project")
        XCTAssertEqual(jobs.status?.succeeded, true)
    }

    /// A queue file written before projects existed (name, job, added, sizes) still reads, and
    /// its names are found wherever the minis are now.
    func testAQueueFileFromBeforeProjectsStillWorks() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let d = try fx.mini("raven", in: "Tiefling Party")
        try """
        [
          {
            "added" : "2026-09-28T10:00:00Z",
            "job" : "prep",
            "name" : "raven",
            "sizes" : { "height" : "54", "nozzle" : "0.4" }
          }
        ]
        """.write(to: runs.appendingPathComponent(".queue.json"), atomically: true, encoding: .utf8)
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder()))
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["raven"])
        jobs.pump()
        jobs.waitUntilDone()
        XCTAssertEqual(ran(fx), [d.appendingPathComponent("raven.stl").path])
        XCTAssertEqual(MiniSettings.load(d).made, Sizes(height: "54", nozzle: "0.4"))
    }

    /// The first run's time estimates are seeded from finished minis in projects too.
    func testPastMinisInProjectsSeedTheEstimates() throws {
        let fx = try Fixture()
        let d = try fx.mini("raven", in: "Tiefling Party")
        try MiniSettings.update(d) { $0.source = .desc; $0.requested = self.sizes }
        try "[1/3] Getting the picture ready\n[2/3] Building the 3D shape\n[3/3] Making the print-ready file\n"
            .write(to: d.appendingPathComponent("generate.job.log"), atomically: true, encoding: .utf8)
        fm.createFile(atPath: d.appendingPathComponent("pixal3d.log").path, contents: nil)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for (f, born, changed) in [("generate.job.log", 0.0, 360.0), ("pixal3d.log", 60, 359), ("raven.stl", 366, 366)] {
            try fm.setAttributes([.creationDate: t0.addingTimeInterval(born), .modificationDate: t0.addingTimeInterval(changed)],
                                 ofItemAtPath: d.appendingPathComponent(f).path)
        }
        XCTAssertEqual(Timings.importPast(runs: fx.install.runs).count, 1)
    }

    /// Resize All leaves out minis already that size, and skips ones with no 3D model or busy.
    func testResizeAllPicksWhichMinisToResize() throws {
        let fx = try Fixture(), runs = fx.install.runs
        for name in ["wizard", "raven", "rogue", "bard"] { _ = try fx.mini(name, in: "Party") }
        try MiniSettings.update(runs.appendingPathComponent("Party/raven")) { $0.made = self.sizes }
        try MiniSettings.update(runs.appendingPathComponent("Party/wizard")) { $0.made = Sizes(height: "28", nozzle: "0.4") }
        try fm.removeItem(at: runs.appendingPathComponent("Party/bard/model.glb"))
        // An object keeps its own no-base, whatever the card says.
        _ = try fx.mini("teapot", in: "Party")
        try MiniSettings.update(runs.appendingPathComponent("Party/teapot")) { $0.kind = .object; $0.made = Sizes(height: "80", nozzle: "0.4", noBase: true) }
        let picked = Gallery.toResize(Gallery.list(runs), to: sizes, busy: ["rogue"])
        let resize = Dictionary(uniqueKeysWithValues: picked.resize.map { ($0.mini.name, $0.sizes) })
        XCTAssertEqual(Set(resize.keys), ["wizard", "teapot"])
        XCTAssertEqual(resize["wizard"], sizes)
        XCTAssertEqual(resize["teapot"]?.noBase, true)
        XCTAssertEqual(resize["teapot"]?.height, sizes.height)
        XCTAssertEqual(picked.same, 1)
        XCTAssertEqual(picked.skipped, 2)
    }

    /// A hex Resize All leaves an object without a base as it is: with no base there's no shape,
    /// so it's already that size, not resized again for a shape it can't have.
    func testResizeAllToAShapeLeavesAnObjectWithoutABaseAlone() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("teapot", in: "Party")
        _ = try fx.mini("wizard", in: "Party")
        try MiniSettings.update(runs.appendingPathComponent("Party/teapot")) { $0.kind = .object; $0.made = Sizes(height: "32", base: "25", nozzle: "0.4", noBase: true) }
        try MiniSettings.update(runs.appendingPathComponent("Party/wizard")) { $0.made = Sizes(height: "32", base: "25", nozzle: "0.4") }
        let picked = Gallery.toResize(Gallery.list(runs), to: Sizes(height: "32", base: "25", nozzle: "0.4", shape: .hex, style: .stone, magnet: .mm5x2), busy: [])
        XCTAssertEqual(picked.resize.map(\.mini.name), ["wizard"], "the round wizard becomes hex")
        XCTAssertEqual(picked.resize.first?.sizes.shape, .hex)
        XCTAssertEqual(picked.resize.first?.sizes.magnet, .mm5x2)
        XCTAssertEqual(picked.same, 1, "the teapot has no base to make hex or put a magnet in")
    }

    /// Several minis in the Trash: every one but the one being made, which is named.
    func testTrashingSeveralLeavesTheOneBeingMade() throws {
        let fx = try Fixture(), runs = fx.install.runs
        for name in ["wizard", "raven", "rogue"] { _ = try fx.mini(name) }
        let minis = Gallery.list(runs)
        let picked = Gallery.toTrash(minis, busyWith: "raven")
        XCTAssertEqual(Set(picked.trash.map(\.name)), ["wizard", "rogue"])
        XCTAssertEqual(picked.staying?.name, "raven")
        XCTAssertEqual(Gallery.toTrash(minis, busyWith: nil).trash.count, 3)
        XCTAssertNil(Gallery.toTrash(minis, busyWith: "bard").staying, "being made, but not among them")
    }

    /// Minis dragged together arrive as their names, however many came in one item.
    func testSeveralMinisDragAsOne() {
        let one = Gallery.dragged(["wizard", "raven"])
        XCTAssertEqual(Gallery.dropped([one]), ["wizard", "raven"])
        XCTAssertEqual(Gallery.dropped(["rogue", one]), ["rogue", "wizard", "raven"])
        XCTAssertEqual(Gallery.dropped([Gallery.dragged(["bard"])]), ["bard"])
    }

    // MARK: Moving, renaming and deleting

    func testMovingAMiniTakesAllItsFilesAndIsRefusedWhileItsBusy() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let d = try fx.mini("dwarf")
        try "log".write(to: d.appendingPathComponent("prep.log"), atomically: true, encoding: .utf8)
        let before = try fm.contentsOfDirectory(atPath: d.path).sorted()
        try Gallery.createProject(runs, "Tiefling Party")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 1)))
        try jobs.move(mini: "dwarf", toProject: "Tiefling Party")
        let moved = runs.appendingPathComponent("Tiefling Party/dwarf")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: moved.path).sorted(), before)
        XCTAssertFalse(fm.fileExists(atPath: d.path))
        XCTAssertEqual(Gallery.list(runs).first?.project, "Tiefling Party")
        try jobs.move(mini: "dwarf", toProject: nil)
        XCTAssertTrue(fm.fileExists(atPath: d.appendingPathComponent("dwarf.stl").path))
        XCTAssertThrowsError(try jobs.move(mini: "dwarf", toProject: "Nope")) { XCTAssertEqual($0 as? RequestError, .projectNotFound) }

        _ = try fx.mini("elf")
        try jobs.resize(name: "dwarf", sizes: sizes)
        try jobs.resize(name: "elf", sizes: sizes)
        for n in ["dwarf", "elf"] {  // being made, and waiting
            XCTAssertThrowsError(try jobs.move(mini: n, toProject: "Tiefling Party")) { XCTAssertEqual($0 as? RequestError, .cantMove(n)) }
        }
        jobs.waitUntilDone()
        XCTAssertEqual(ran(fx), [d.appendingPathComponent("dwarf.stl").path, runs.appendingPathComponent("elf/elf.stl").path])
    }

    func testRenamingAProject() throws {
        let fx = try Fixture(), runs = fx.install.runs
        _ = try fx.mini("raven", in: "Tiefling Party")
        _ = try fx.mini("dwarf")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 1)))
        XCTAssertEqual(try jobs.renameProject("Tiefling Party", to: " Tieflings "), "Tieflings")
        XCTAssertEqual(Gallery.folder(runs, "raven")?.deletingLastPathComponent().lastPathComponent, "Tieflings")
        XCTAssertEqual(try jobs.renameProject("Tieflings", to: "TIEFLINGS"), "TIEFLINGS")
        XCTAssertEqual(Gallery.projects(runs), ["TIEFLINGS"])
        XCTAssertThrowsError(try jobs.renameProject("TIEFLINGS", to: "Dwarf")) { XCTAssertEqual($0 as? RequestError, .projectTaken("Dwarf")) }
        try jobs.resize(name: "raven", sizes: sizes)
        XCTAssertThrowsError(try jobs.renameProject("TIEFLINGS", to: "Other")) { XCTAssertEqual($0 as? RequestError, .projectBusy("TIEFLINGS", "raven")) }
        jobs.waitUntilDone()
    }

    func testDeletingAProjectKeepsItsMinisOrTrashesThem() throws {
        let fx = try Fixture(), runs = fx.install.runs
        let raven = try fx.mini("raven", in: "Keep")
        fm.createFile(atPath: runs.appendingPathComponent("Keep/my-notes.txt").path, contents: Data([1]))
        _ = try fx.mini("orc", in: "Bin")
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.recorder(sleep: 1)), trash: { spy($0) })

        try jobs.deleteProject("Keep")  // the default keeps them
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("raven/raven.stl").path))
        XCTAssertFalse(fm.fileExists(atPath: raven.path))
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["Keep"], "the folder (with my-notes.txt) goes to the Trash, not away")
        XCTAssertNil(Gallery.list(runs).first { $0.name == "raven" }?.project)

        try jobs.resize(name: "orc", sizes: sizes)
        XCTAssertThrowsError(try jobs.deleteProject("Bin", keepMinis: false)) { XCTAssertEqual($0 as? RequestError, .projectBusy("Bin", "orc")) }
        jobs.waitUntilDone()
        try jobs.deleteProject("Bin", keepMinis: false)
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["Keep", "Bin"])
        XCTAssertTrue(fm.fileExists(atPath: runs.appendingPathComponent("Bin/orc/orc.stl").path), "the spy trashes nothing: the minis weren't moved out first")
    }
}

extension ProjectTests {
    /// Stop on a new mini in a project trashes that folder, not a same-named one elsewhere, and
    /// leaves the project. (Leftover needs no test of its own here: it's keyed on runs/.job.pid,
    /// never on a mini's path.)
    func testStoppingANewMiniInAProjectTrashesItsOwnFolder() throws {
        let fx = try Fixture(), runs = fx.install.runs
        try fx.modelFiles()
        try Gallery.createProject(runs, "Birds")
        let picture = fx.root.appendingPathComponent("pic.png"); fm.createFile(atPath: picture.path, contents: Data([1]))
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 5")), trash: { spy($0) })
        XCTAssertNil(try jobs.make(name: "raven", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                   model: EngineDownload.standard, project: "Birds"))
        for _ in 0..<100 where jobs.status?.step != 2 { usleep(50_000) }
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(spy.trashed.map(\.path), [runs.appendingPathComponent("Birds/raven").path])
        XCTAssertEqual(Gallery.projects(runs), ["Birds"])
    }
}
