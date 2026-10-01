import XCTest
@testable import MimicCore

/// What `mimic` in Terminal shares with the app's menus (#129): Stop from another Mimic, Rename,
/// Move to Trash, Keep This One, Resize All and Info.
final class MiniActionsTests: XCTestCase {
    let sizes = Sizes(height: "32", base: "25", nozzle: "0.4")

    /// Holds the job lock as another Mimic would, so jobs asked for wait in the queue.
    private func anotherMimic(_ fx: Fixture) -> Int32 {
        let fd = open(fx.install.queue.appendingPathComponent("job.lock").path, O_CREAT | O_RDWR, 0o644)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        return fd
    }

    /// `mimic stop` is another program than the Mimic making the mini: it can only ask. Two
    /// runners on one folder are two Mimics as far as the locks are concerned.
    func testStopAsksTheMimicMakingItToStop() throws {
        let fx = try Fixture()
        let started = fx.root.appendingPathComponent("started").path
        let engine = try fx.script("fake-engine", "touch \(started); sleep 60 & wait")
        try fx.modelFiles()
        let maker = JobRunner(install: fx.install, tools: fx.tools(mimic: engine), trash: { _ in })
        let terminal = JobRunner(install: fx.install, tools: fx.tools())
        XCTAssertEqual(terminal.stopElsewhere(timeout: 1), .nothing)
        try maker.make(name: "mini", picture: .image(try fx.picture()), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }

        // A request left from before, naming another job, is dropped rather than kept for later.
        try Data("someone-else".utf8).write(to: maker.queue.stopFile)
        XCTAssertTrue(eventually { !FileManager.default.fileExists(atPath: maker.queue.stopFile.path) }, "the request was never read")
        XCTAssertEqual(maker.status?.running, true, "a request naming another mini stopped this one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: maker.queue.stopFile.path))
        // So is one for an earlier job of the same name (#173).
        let earlier = JobStatus(name: "mini", kind: .prep, step: 3, started: Date(timeIntervalSinceNow: -3600))
        try Data(JobRunner.stopAsk(earlier).utf8).write(to: maker.queue.stopFile)
        XCTAssertTrue(eventually { !FileManager.default.fileExists(atPath: maker.queue.stopFile.path) }, "the request was never read")
        XCTAssertEqual(maker.status?.running, true, "a request for an earlier job of this name stopped this one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: maker.queue.stopFile.path))

        guard case .stopped(let s) = terminal.stopElsewhere(timeout: 10) else { return XCTFail("the Mimic making it didn't stop it") }
        XCTAssertEqual(s.name, "mini")
        maker.waitUntilDone()
        XCTAssertEqual(maker.status?.canceled, true, "stopped as Stop does, not failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: maker.queue.stopFile.path))
    }

    /// A stopped new mini's folder goes to the Trash, and with it the name it was given: it's
    /// named as typed all the same, not "Elodie The Druid" from its folder (#166).
    func testAStoppedMiniIsNamedAsTyped() throws {
        let fx = try Fixture()
        let started = fx.root.appendingPathComponent("started").path
        let engine = try fx.script("fake-engine", "touch \(started); sleep 60 & wait")
        try fx.modelFiles()
        let maker = JobRunner(install: fx.install, tools: fx.tools(mimic: engine), trash: { try FileManager.default.removeItem(at: $0) })
        let terminal = JobRunner(install: fx.install, tools: fx.tools())
        try maker.make(name: "elodie-the-druid", picture: .image(try fx.picture()), restyle: false, seed: 1, sizes: sizes,
                       model: EngineDownload.standard, shown: "Élodie the Druid")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }

        guard case .stopped(let s) = terminal.stopElsewhere(timeout: 10) else { return XCTFail("the Mimic making it didn't stop it") }
        maker.waitUntilDone()
        let runs = fx.install.runs
        XCTAssertNil(Gallery.folder(runs, "elodie-the-druid"), "a stopped new mini goes to the Trash")
        XCTAssertEqual(Mini.displayName("elodie-the-druid", runs: runs), "Elodie The Druid", "the folder is gone, so it can't name it")
        XCTAssertEqual(s.displayName(runs: runs), "Élodie the Druid", "mimic stop")
        XCTAssertEqual(maker.status?.displayName(runs: runs), "Élodie the Druid", "Mimic's toolbar and job popover")
    }

    /// The job ends on its own before the Mimic making it reads the request (#173): `mimic stop`
    /// doesn't say it stopped it, and the request goes, so the next job of that name isn't stopped.
    func testAStopThatCameTooLateSaysSoAndIsTakenBack() throws {
        let fx = try Fixture()
        // Just short of a whole second: what `mimic stop` reads from job.json still matches it.
        let job = JobStatus(name: "mini", kind: .prep, step: 3, started: Date(timeIntervalSince1970: 1_700_000_000.9999))
        SharedJob.write(job, queue: fx.install.queue)  // another Mimic, which finishes it before it looks
        XCTAssertEqual(JobRunner.stopTime(try XCTUnwrap(SharedJob.read(queue: fx.install.queue)).started), JobRunner.stopTime(job.started))
        let terminal = JobRunner(install: fx.install, tools: fx.tools())
        // Finished once `mimic stop` has asked, not before.
        let stopFile = terminal.queue.stopFile.path
        DispatchQueue.global().async {
            _ = eventually { FileManager.default.fileExists(atPath: stopFile) }
            SharedJob.clear(queue: fx.install.queue)
        }
        guard case .ended(let s) = terminal.stopElsewhere(timeout: 10) else { return XCTFail("said it stopped a job that ended on its own") }
        XCTAssertEqual(s.name, "mini")
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.queue.stopFile.path), "the request was left for a later job")

        // Later, the same mini is resized: it runs.
        let started = fx.root.appendingPathComponent("started").path
        let prep = try fx.script("fake-prep", "touch \(started); sleep 60 & wait")
        _ = try fx.mini("mini")
        let maker = JobRunner(install: fx.install, tools: fx.tools(mimic: prep), trash: { _ in })
        try maker.resize(name: "mini", sizes: sizes)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }
        // It has looked for a request once it drops this one, naming another mini.
        try Data("someone-else".utf8).write(to: maker.queue.stopFile)
        XCTAssertTrue(eventually { !FileManager.default.fileExists(atPath: maker.queue.stopFile.path) }, "the request was never read")
        XCTAssertEqual(maker.status?.running, true, "a request from before stopped the next job of that name")
        XCTAssertTrue(maker.cancel())
        maker.waitUntilDone()
    }

    /// Unanswered (a Mimic from before 0.9.0), the request is taken back, so it can't stop a later
    /// job of the same name.
    func testAnUnansweredStopIsTakenBack() throws {
        let fx = try Fixture()
        let job = JobStatus(name: "mini", kind: .generate, step: 2, started: Date())
        SharedJob.write(job, queue: fx.install.queue)  // as if another Mimic were making it, and deaf
        let terminal = JobRunner(install: fx.install, tools: fx.tools())
        guard case .noAnswer = terminal.stopElsewhere(timeout: 0.5) else { return XCTFail("no Mimic stopped it") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminal.queue.stopFile.path))
    }

    func testRenameTakesATypedNameAndRefusesAWaitingMini() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); _ = try fx.mini("b")
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        XCTAssertEqual(try jobs.rename("b", typed: "  Élodie  "), "elodie")
        XCTAssertEqual(Mini.displayName("elodie", runs: fx.install.runs), "Élodie")
        XCTAssertThrowsError(try jobs.rename("elodie", typed: " \n ")) { XCTAssertEqual($0 as? RequestError, .noName) }

        // Waiting: a job finds its folder by name as it starts, so renaming it now would lose it.
        let fd = anotherMimic(fx); defer { close(fd) }
        try jobs.resize(name: "a", sizes: sizes)
        XCTAssertThrowsError(try jobs.rename("a", typed: "Alpha")) { XCTAssertEqual($0 as? RequestError, .renameWaiting("a")) }
        XCTAssertNotNil(Gallery.folder(fx.install.runs, "a"))
    }

    func testTrashTakesAWaitingMiniOutOfTheQueueFirst() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        try fx.modelFiles()
        let runnerTrash = TrashSpy(), trash = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(), trash: { runnerTrash($0) })
        let fd = anotherMimic(fx); defer { close(fd) }

        // Waiting to be resized: out of the queue, then its folder to the Trash.
        try jobs.resize(name: "a", sizes: sizes)
        let a = try XCTUnwrap(Gallery.list(fx.install.runs).first { $0.name == "a" })
        let moved = try jobs.moveToTrash(a, trash: { trash($0) })
        XCTAssertEqual(moved?.folder.lastPathComponent, "a")
        XCTAssertEqual(trash.trashed.map(\.lastPathComponent), ["a"])
        XCTAssertEqual(jobs.queue.entries(), [])

        // A new mini waiting to be made: leaving the queue sends its folder to the Trash already.
        try jobs.make(name: "new", picture: .image(try fx.picture()), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        let new = try XCTUnwrap(Gallery.list(fx.install.runs).first { $0.name == "new" })
        XCTAssertNil(try jobs.moveToTrash(new, trash: { trash($0) }))
        XCTAssertEqual(runnerTrash.trashed.map(\.lastPathComponent), ["new"])
        XCTAssertEqual(trash.trashed.count, 1, "trashed twice")
        XCTAssertEqual(jobs.queue.entries(), [])
    }

    func testKeepTrashesTheOtherVersionsButNotTheOneBeingMade() {
        func mini(_ name: String, of root: String? = nil, project: String? = nil) -> Mini {
            var s = MiniSettings(); s.versionOf = root
            return Mini(name: name, folder: URL(fileURLWithPath: "/runs/\(name)"), madeAt: Date(), project: project, settings: s)
        }
        let minis = [mini("orc"), mini("orc-2", of: "orc"), mini("orc-3", of: "orc"), mini("elf"), mini("orc-4", of: "orc", project: "Party")]
        let kept = Gallery.toKeep(minis[1], in: minis, busyWith: "orc-3")
        XCTAssertEqual(kept.trash.map(\.name), ["orc"])
        XCTAssertEqual(kept.staying?.name, "orc-3")
        XCTAssertEqual(Gallery.toKeep(minis[3], in: minis, busyWith: nil).trash, [])
    }

    func testResizeAllLeavesOutTheBusyAndThoseAlreadyThatSize() throws {
        let fx = try Fixture()
        for n in ["a", "b", "c"] { _ = try fx.mini(n) }
        try MiniSettings.update(fx.install.runs.appendingPathComponent("b")) { $0.made = self.sizes }
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        let fd = anotherMimic(fx); defer { close(fd) }
        try jobs.resize(name: "c", sizes: Sizes(height: "50"))  // already waiting
        var asked: [String] = []
        let done = jobs.resizeAll(Gallery.list(fx.install.runs), to: sizes) { m, _ in asked.append(m.name) }
        XCTAssertEqual(asked, ["a"])
        XCTAssertEqual(done.added, ["a"])
        XCTAssertEqual(done.same, 1)
        XCTAssertEqual(done.skipped, 1)
        XCTAssertNil(done.nothingAdded(nil))
        XCTAssertEqual(done.sameNote + done.skippedNote, " 1 was already that size. Skipped 1: not made yet, or already waiting or being made.")

        let refused = jobs.resizeAll(Gallery.list(fx.install.runs).filter { $0.name == "a" }, to: sizes) { _, _ in throw RequestError.noModelYet }
        XCTAssertEqual(refused.nothingAdded("Not yet."), "Not yet. Skipped 1: not made yet, or already waiting or being made.")
        let same = jobs.resizeAll(Gallery.list(fx.install.runs).filter { $0.name == "b" }, to: sizes) { _, _ in XCTFail("resized a mini already that size") }
        XCTAssertEqual(same.nothingAdded(nil), "They're all already that size.")
    }

    /// Measured as the 3D view turns a print file: tall is its Z extent, wide its X, deep its Y.
    func testMeasuredFromAPrintFile() throws {
        let fx = try Fixture()
        // A box 26 wide, 25 deep and 34 tall, as two triangles per side would be; corners are what count.
        let corners: [SIMD3<Float>] = [[0, 0, 0], [26, 0, 0], [26, 25, 0], [0, 0, 34], [26, 25, 34], [0, 25, 34]]
        let mesh = Mesh(positions: corners, triangles: [[0, 1, 2], [3, 4, 5]])
        let stl = fx.root.appendingPathComponent("box.stl")
        try STL.write(mesh, to: stl)
        let m = try XCTUnwrap(Measured(stl: stl))
        XCTAssertEqual([m.tall, m.wide, m.deep], [34, 26, 25])
        XCTAssertEqual(m.caption, "34 mm tall · 26 × 25 mm")
        XCTAssertNil(Measured(stl: fx.root.appendingPathComponent("missing.stl")))
    }

    func testInfoSaysWhatTheMinisPageSays() throws {
        let fx = try Fixture(); _ = try fx.mini("orc"); let d = try fx.mini("orc-2")
        try MiniSettings.update(d) {
            $0.made = self.sizes; $0.source = .desc; $0.desc = "an orc with an axe"; $0.seed = 7; $0.versionOf = "orc"
            $0.name("Grok 2", folder: "orc-2")
        }
        let minis = Gallery.list(fx.install.runs), mini = try XCTUnwrap(minis.first { $0.name == "orc-2" })
        let lines = MiniInfo(mini, in: minis, waiting: []).lines
        XCTAssertEqual(lines.first, "Grok 2 (orc-2)")
        for want in ["State: ready", "Character: 32 mm", "Base: 25 mm", "Nozzle: 0.4 mm", "Source: A description",
                     "Variation number: 7", "Description: an orc with an axe", "Versions: orc, orc-2 (this one)"] {
            XCTAssertTrue(lines.contains(want), "missing \(want) in \(lines)")
        }
        XCTAssertEqual(MiniInfo(mini, in: minis, waiting: ["orc-2"]).state, .waiting)
    }
}
