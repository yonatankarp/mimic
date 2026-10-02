import ImageIO
import XCTest
@testable import MimicCore

/// The queue shared by every Mimic. Two JobRunners on one runs folder stand in for two Mimics
/// (the app and the dev app, or the app and `mimic`): each takes its own open of the lock files,
/// which is exactly what keeps two processes apart.
final class QueueTests: XCTestCase {
    let sizes = Sizes(height: "32", nozzle: "0.4")

    /// Print prep that fails (99) if another job is inside it at the same moment, and notes
    /// which mini it made.
    func overlapCatcher(_ fx: Fixture, hold: Double = 0.05) throws -> String {
        let runs = fx.install.runs.path, ran = fx.root.appendingPathComponent("ran.txt").path
        return try fx.script("prep", """
        mkdir "\(runs)/.inflight" 2>/dev/null || exit 99
        echo "$3" >> "\(ran)"
        sleep \(hold)
        rmdir "\(runs)/.inflight"
        """)
    }

    func ran(_ fx: Fixture) -> [String] {
        ((try? String(contentsOf: fx.root.appendingPathComponent("ran.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map { URL(fileURLWithPath: String($0)).deletingPathExtension().lastPathComponent }
    }

    /// Two Mimics asking for jobs at once, from two threads: every job runs exactly once, never
    /// two at the same time, and nothing is left waiting.
    func testTwoMimicsNeverRunTwoJobsAndLoseNone() throws {
        let fx = try Fixture()
        let names = (0..<16).map { "m\($0)" }
        for n in names { _ = try fx.mini(n) }
        let prep = try overlapCatcher(fx)
        let a = JobRunner(install: fx.install, tools: fx.tools(mimic: prep))
        let b = JobRunner(install: fx.install, tools: fx.tools(mimic: prep))
        let failures = TrashSpy()
        for r in [a, b] { r.onChange = { s in if !s.running && !s.succeeded { failures(URL(fileURLWithPath: s.name)) } } }
        let sizes = sizes  // not self: the closure runs on other threads
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            for n in names.enumerated().filter({ $0.offset % 2 == i }).map(\.element) {
                do { _ = try (i == 0 ? a : b).resize(name: n, sizes: sizes) } catch { XCTFail("\(n): \(error)") }
            }
        }
        for _ in 0..<3 { a.waitUntilDone(); b.waitUntilDone() }
        XCTAssertEqual(failures.trashed, [], "a job failed: two ran at once (exit 99)")
        XCTAssertEqual(ran(fx).sorted(), names.sorted(), "every job runs exactly once")
        XCTAssertEqual(a.queue.entries(), [], "a job was left waiting with nobody to run it")
    }

    /// Hundreds of additions from two Mimics at once: none lost to a read-change-write race.
    func testNoAdditionIsLost() throws {
        let fx = try Fixture()
        let queues = [JobQueue(folder: fx.install.queue), JobQueue(folder: fx.install.queue)]
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            for k in 0..<150 {
                do { try queues[i].locked { $0.append(QueueEntry(name: "q\(i)-\(k)", job: .prep)) } } catch { XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(queues[0].entries().count, 300)
    }

    /// A queue file that won't read (#306) is never written over as if it were empty: it's put
    /// aside, bytes untouched, and the change goes on in a new one. Garbage, a cut-off write, and
    /// a job kind from a newer Mimic (Codable skips an unknown field, not an unknown case).
    func testAQueueThatWontReadIsPutAsideNotWrittenOver() throws {
        let waiting = #"[{"name":"dwarf","job":"generate","added":"2026-01-01T00:00:00Z"},"#
        let newer = #"[{"name":"dwarf","job":"paint","added":"2026-01-01T00:00:00Z"}]"#
        for bad in ["not json", waiting, newer] {
            let fx = try Fixture()
            let queue = JobQueue(folder: fx.install.queue)
            try FileManager.default.createDirectory(at: queue.folder, withIntermediateDirectories: true)
            try Data(bad.utf8).write(to: queue.file)
            try queue.locked { $0.append(QueueEntry(name: "elf", job: .prep)) }
            XCTAssertEqual(queue.entries().map(\.name), ["elf"], bad)
            let aside = queue.setAside()
            XCTAssertEqual(aside.count, 1, "the unreadable queue was written over: \(bad)")
            XCTAssertEqual(try aside.first.map { try String(contentsOf: $0, encoding: .utf8) }, bad)
        }
        // One Mimic can't open at all (its permissions changed): put aside too, not replaced.
        let fx = try Fixture()
        let queue = JobQueue(folder: fx.install.queue)
        try queue.locked { $0.append(QueueEntry(name: "dwarf", job: .prep)) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: queue.file.path)
        try queue.locked { $0.append(QueueEntry(name: "elf", job: .prep)) }
        let aside = try XCTUnwrap(queue.setAside().first, "the queue it couldn't open was written over")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aside.path)
        XCTAssertEqual(try JobQueue.decoder.decode([QueueEntry].self, from: Data(contentsOf: aside)).map(\.name), ["dwarf"])
        XCTAssertEqual(queue.entries().map(\.name), ["elf"])
    }

    /// No queue file yet is just an empty queue, with nothing put aside; a good one round-trips.
    func testAQueueThatReadsIsKept() throws {
        let fx = try Fixture()
        let queue = JobQueue(folder: fx.install.queue)
        let entry = QueueEntry(name: "elf", job: .prep, added: Date(timeIntervalSince1970: 1_800_000_000), sizes: sizes, again: true)
        try queue.locked { $0.append(entry) }
        try queue.locked { $0.append(QueueEntry(name: "orc", job: .generate)) }
        XCTAssertEqual(queue.entries().first, entry)
        XCTAssertEqual(queue.entries().map(\.name), ["elf", "orc"])
        XCTAssertEqual(queue.setAside(), [])
    }

    /// When it can't even be put aside, the change is refused rather than written over it.
    func testAQueueThatCantBePutAsideRefusesTheChange() throws {
        let fx = try Fixture()
        let queue = JobQueue(folder: fx.install.queue)
        try FileManager.default.createDirectory(at: queue.folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: queue.lockFile.path, contents: nil)
        try Data("not json".utf8).write(to: queue.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: queue.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: queue.folder.path) }
        XCTAssertThrowsError(try queue.locked { $0.append(QueueEntry(name: "elf", job: .prep)) })
        XCTAssertEqual(try String(contentsOf: queue.file, encoding: .utf8), "not json")
    }

    /// First in, first made; a waiting job can be moved up or taken out.
    func testOrderMoveAndRemove() throws {
        let fx = try Fixture()
        for n in ["a", "b", "c", "d"] { _ = try fx.mini(n) }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try overlapCatcher(fx, hold: 0.5)))
        XCTAssertNil(try jobs.resize(name: "a", sizes: sizes))
        XCTAssertEqual(try jobs.resize(name: "b", sizes: sizes), 1)
        XCTAssertEqual(try jobs.resize(name: "c", sizes: sizes), 2)
        XCTAssertEqual(try jobs.resize(name: "d", sizes: sizes), 3)
        try jobs.move("d", by: -1)
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["b", "d", "c"])
        XCTAssertTrue(try jobs.remove("c"))
        XCTAssertFalse(try jobs.remove("a"), "the running job isn't waiting")
        jobs.waitUntilDone()
        XCTAssertEqual(ran(fx), ["a", "b", "d"])
    }

    /// Pause after this one (#89): the running job finishes, nothing after it starts, in this
    /// Mimic or another (the pause is on disk), and resuming carries on in order.
    func testPauseAfterThisOneHoldsTheQueueForEveryMimic() throws {
        let fx = try Fixture()
        for n in ["a", "b", "c"] { _ = try fx.mini(n) }
        let prep = try overlapCatcher(fx, hold: 0.5)
        let a = JobRunner(install: fx.install, tools: fx.tools(mimic: prep))
        let b = JobRunner(install: fx.install, tools: fx.tools(mimic: prep))
        XCTAssertNil(try a.resize(name: "a", sizes: sizes))
        XCTAssertEqual(try a.resize(name: "b", sizes: sizes), 1)
        try a.setPaused(true)
        a.waitUntilDone()
        XCTAssertEqual(ran(fx), ["a"], "the one running finishes, and nothing after it starts")
        XCTAssertEqual(a.queue.entries().map(\.name), ["b"])
        XCTAssertEqual(b.hold(), .paused, "another Mimic sees the pause")
        b.pump()
        XCTAssertNil(b.status, "another Mimic started the paused queue")
        XCTAssertEqual(try b.resize(name: "c", sizes: sizes), 1, "one ahead of it, and nothing running")
        XCTAssertNil(b.status)
        try b.setPaused(false)
        XCTAssertNil(a.hold())
        b.waitUntilDone()
        XCTAssertEqual(ran(fx), ["a", "b", "c"])
        XCTAssertEqual(b.queue.entries(), [])
    }

    /// Start minis only when plugged in: nothing new starts while the Mac is on battery, and the
    /// queue carries on when it's plugged in and someone looks again.
    func testNothingStartsOnBattery() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let battery = Flag(true)
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        jobs.heldForPower = { battery.value }
        XCTAssertEqual(try jobs.resize(name: "a", sizes: sizes), 0, "nothing ahead of it")
        XCTAssertNil(jobs.status, "it started on battery")
        XCTAssertEqual(jobs.hold(), .battery)
        jobs.pump()
        XCTAssertNil(jobs.status)
        battery.value = false  // plugged in
        jobs.pump()
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.succeeded, true)
        XCTAssertEqual(jobs.queue.entries(), [])
    }

    /// A job's programs run at a lower priority, so the Mac stays quick to use meanwhile (#89).
    func testJobProgramsRunAtALowerPriority() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let out = fx.root.appendingPathComponent("nice.txt")
        let prep = try fx.script("prep", "ps -o nice= -p $$ > \(out.path)")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: prep))
        try jobs.resize(name: "a", sizes: sizes)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.succeeded, true)
        // nice adds to what it's started with: whatever runs the tests may already be niced.
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                       String(min(20, getpriority(PRIO_PROCESS, 0) + 10)))
    }

    /// Reordering the queue (#72): to the front, the end or a place, and up or down, one mini at
    /// a time. The mini being made isn't moved, and a move never stops it.
    func testMoveToTheFrontTheEndOrAPlace() throws {
        let fx = try Fixture()
        for n in ["a", "b", "c", "d", "e"] { _ = try fx.mini(n) }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try overlapCatcher(fx, hold: 0.5)))
        XCTAssertNil(try jobs.resize(name: "a", sizes: sizes))
        for n in ["b", "c", "d", "e"] { try jobs.resize(name: n, sizes: sizes) }
        func order() -> [String] { jobs.queue.entries().map(\.name) }
        XCTAssertTrue(try jobs.move("e", to: .front)); XCTAssertEqual(order(), ["e", "b", "c", "d"])
        XCTAssertTrue(try jobs.move("e", to: .end)); XCTAssertEqual(order(), ["b", "c", "d", "e"])
        XCTAssertTrue(try jobs.move("b", to: .position(3))); XCTAssertEqual(order(), ["c", "d", "b", "e"])
        XCTAssertTrue(try jobs.move("c", to: .position(99))); XCTAssertEqual(order(), ["d", "b", "e", "c"])
        XCTAssertTrue(try jobs.move("c", by: -1)); XCTAssertEqual(order(), ["d", "b", "c", "e"])
        XCTAssertTrue(try jobs.move("d", by: 1)); XCTAssertEqual(order(), ["b", "d", "c", "e"])
        XCTAssertFalse(try jobs.move("a", to: .front), "the mini being made isn't waiting")
        XCTAssertFalse(try jobs.move("nobody", to: .end))
        XCTAssertEqual(jobs.status?.name, "a")
        XCTAssertEqual(jobs.status?.running, true, "a move stopped the mini being made")
        XCTAssertEqual(QueuePlace("front"), .front)
        XCTAssertEqual(QueuePlace("END"), .end)
        XCTAssertEqual(QueuePlace("2"), .position(2))
        XCTAssertNil(QueuePlace("0"))
        XCTAssertNil(QueuePlace("soon"))
        jobs.waitUntilDone()
        XCTAssertEqual(ran(fx), ["a", "b", "d", "c", "e"], "made in the new order")
    }

    /// Two Mimics reordering and adding at once: every move goes through the queue's lock, so
    /// no addition is lost to a move that read the queue before it.
    func testMovesAndAdditionsFromTwoMimicsLoseNothing() throws {
        let fx = try Fixture()
        let adder = JobQueue(folder: fx.install.queue)
        let mover = JobRunner(install: fx.install, tools: fx.tools())
        try adder.locked { $0 = (0..<5).map { QueueEntry(name: "start\($0)", job: .prep) } }
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            for k in 0..<150 {
                do {
                    if i == 0 { try adder.locked { $0.append(QueueEntry(name: "q\(k)", job: .prep)) } }
                    else { try mover.move("start\(k % 5)", to: k % 2 == 0 ? .front : .end) }
                } catch { XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(adder.entries().count, 155)
    }

    /// A queued new mini is on disk at once (its picture, its settings) and shows as unfinished;
    /// taking it out of the queue sends its folder to the Trash, as stopping it would.
    func testAQueuedMiniIsWrittenAtOnceAndRemovingItTrashesIt() throws {
        let fx = try Fixture(); _ = try fx.mini("first")
        try fx.modelFiles()
        let picture = try fx.picture("photo.jpg")
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 1")), trash: { spy($0) })
        try jobs.resize(name: "first", sizes: sizes)
        XCTAssertEqual(try jobs.make(name: "second", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                     model: EngineDownload.standard), 1)
        let folder = fx.install.runs.appendingPathComponent("second")
        let upload = try XCTUnwrap(CGImageSourceCreateWithURL(folder.appendingPathComponent("upload.img") as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(upload) as String?, "public.png", "the picture was kept as it came, not tidied")
        XCTAssertEqual(MiniSettings.load(folder).requested, sizes)
        XCTAssertThrowsError(try jobs.make(name: "second", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard)) { XCTAssertEqual($0 as? RequestError, .queued("second")) }
        // Refused before anything is written: a picture that's gone.
        XCTAssertThrowsError(try jobs.make(name: "third", picture: .image(fx.root.appendingPathComponent("gone.png")), restyle: false,
                                           seed: 1, sizes: sizes, model: EngineDownload.standard)) { XCTAssertEqual($0 as? RequestError, .noPicture) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("third").path))
        // And one that isn't a picture at all.
        let notes = fx.root.appendingPathComponent("notes.png"); FileManager.default.createFile(atPath: notes.path, contents: Data("hi".utf8))
        XCTAssertThrowsError(try jobs.make(name: "third", picture: .image(notes), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard)) { XCTAssertEqual($0 as? RequestError, .unreadablePicture) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("third").path))
        XCTAssertTrue(try jobs.remove("second"))
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["second"])
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.name, "first", "the removed mini ran anyway")
    }

    /// mimic queue remove says which mini by its name as shown (#137), read before its folder,
    /// which keeps that name, goes to the Trash.
    func testRemovingSaysTheNameAsShown() throws {
        let fx = try Fixture(); _ = try fx.mini("first")
        try fx.modelFiles()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 1")),
                             trash: { try FileManager.default.removeItem(at: $0) })
        try jobs.resize(name: "first", sizes: sizes)
        XCTAssertEqual(try jobs.make(name: "big-photo-qa", picture: .image(try fx.picture("photo.jpg")), restyle: false, seed: 1,
                                     sizes: sizes, model: EngineDownload.standard, shown: "Big Photo QA"), 1)
        XCTAssertEqual(try jobs.removeSaying("big-photo-qa"), "Took Big Photo QA out of the queue.")
        XCTAssertNil(Gallery.folder(fx.install.runs, "big-photo-qa"), "its folder went to the Trash")
        XCTAssertNil(try jobs.removeSaying("big-photo-qa"), "it isn't waiting any more")
        jobs.waitUntilDone()
    }

    /// A queued resize keeps the mini's sizes until it starts, then asks for the new ones.
    func testAQueuedResizeWritesItsSizesWhenItStarts() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); let b = try fx.mini("b")
        try MiniSettings.update(b) { $0.requested = Sizes(height: "28") }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 0.5")))
        try jobs.resize(name: "a", sizes: sizes)
        try jobs.resize(name: "b", sizes: Sizes(height: "54"))
        XCTAssertEqual(MiniSettings.load(b).requested, Sizes(height: "28"))
        jobs.waitUntilDone()
        XCTAssertEqual(MiniSettings.load(b).made, Sizes(height: "54"))
    }

    /// Stop ends the running job only: the queue carries on. Quitting (keepGoing off) leaves the
    /// rest waiting for the next Mimic to start.
    func testStopKeepsTheQueueGoingAndQuittingLeavesItWaiting() throws {
        let fx = try Fixture()
        for n in ["a", "b", "c"] { _ = try fx.mini(n) }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 5")))
        try jobs.resize(name: "a", sizes: sizes)
        try jobs.resize(name: "b", sizes: sizes)
        try jobs.resize(name: "c", sizes: sizes)
        XCTAssertTrue(jobs.cancel())
        for _ in 0..<100 where jobs.status?.name != "b" { usleep(50_000) }
        XCTAssertEqual(jobs.status?.name, "b", "Stop ended the queue too")
        jobs.keepGoing = { _ in false }
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["c"])

        // The next Mimic to open picks it up, asking nothing.
        let next = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        next.pump()
        next.waitUntilDone()
        XCTAssertEqual(next.status?.name, "c")
        XCTAssertEqual(next.status?.succeeded, true)
    }

    /// `mimic make` runs the queue only until its own mini is made, then leaves the rest to the app.
    func testARunnerCanStopAfterItsOwnJob() throws {
        let fx = try Fixture()
        for n in ["a", "b", "c"] { _ = try fx.mini(n) }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("slow", "sleep 0.3")))
        jobs.keepGoing = { $0.contains { $0.name == "b" } }
        try jobs.resize(name: "a", sizes: sizes)
        try jobs.resize(name: "b", sizes: sizes)
        try jobs.resize(name: "c", sizes: sizes)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.name, "b")
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["c"])
    }

    /// Another Mimic's running job is visible (job.json) and its program is never taken
    /// for a crash's leftover: only a Mimic that gets the job lock stops one.
    func testALiveJobIsNeverStoppedAsALeftover() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let childFile = fx.root.appendingPathComponent("child.pid").path
        let a = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "echo $$ > \(childFile); sleep 30")))
        try a.resize(name: "a", sizes: sizes)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childFile) { usleep(50_000) }
        let b = JobRunner(install: fx.install, tools: fx.tools())
        b.cleanUpLeftovers()
        b.pump()
        let child = pid_t(try String(contentsOfFile: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(child, 0), 0, "a second Mimic stopped a running job as if it were a crash's leftover")
        XCTAssertEqual(b.running()?.name, "a", "the other Mimic's job isn't visible")
        XCTAssertEqual(b.running()?.kind, .prep)
        XCTAssertThrowsError(try b.resize(name: "a", sizes: sizes)) { XCTAssertEqual($0 as? RequestError, .busy("a", .prep)) }
        a.cancel(); a.waitUntilDone()
        XCTAssertNil(SharedJob.read(queue: fx.install.queue))
    }

    /// A crashed Mimic: its job's program is still running and its queue is still waiting. The
    /// next Mimic stops the leftover and carries on with the queue.
    func testAfterACrashTheNextMimicStopsTheLeftoverAndCarriesOn() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let orphan = try GroupProcess(executable: "/bin/sleep", arguments: ["60"], environment: [:])
        Leftover.record(pid: orphan.pid, queue: fx.install.queue)
        try JobQueue(folder: fx.install.queue).locked { $0.append(QueueEntry(name: "a", job: .prep)) }
        let next = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        next.pump()
        XCTAssertEqual(orphan.wait(), -15, "the crashed job's program was left running")
        next.waitUntilDone()
        XCTAssertEqual(next.status?.name, "a")
        XCTAssertEqual(next.status?.succeeded, true)
    }

    /// With nothing waiting, a crash's leftover is still stopped by the next Mimic to look.
    func testALeftoverIsStoppedWithAnEmptyQueue() throws {
        let fx = try Fixture()
        let orphan = try GroupProcess(executable: "/bin/sleep", arguments: ["60"], environment: [:])
        Leftover.record(pid: orphan.pid, queue: fx.install.queue)
        XCTAssertTrue(Leftover.recorded(queue: fx.install.queue))
        JobRunner(install: fx.install, tools: fx.tools()).cleanUpLeftovers()
        XCTAssertEqual(orphan.wait(), -15)
        XCTAssertFalse(Leftover.recorded(queue: fx.install.queue))
    }

    /// A job's programs must not inherit the locks: when Mimic crashes, which unlocks nothing,
    /// a program still running would hold the lock, and no Mimic could ever start another job.
    func testTheLocksAreNotInheritedByAJobsPrograms() throws {
        let fx = try Fixture()
        let url = fx.install.queue.appendingPathComponent("job.lock")
        let held = JobQueue.openLock(url)
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        let program = try GroupProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:])
        defer { program.terminateGroup(grace: 0) }
        close(held)  // the crash: the lock goes without being let go
        let next = JobQueue.openLock(url)
        defer { close(next) }
        XCTAssertEqual(flock(next, LOCK_EX | LOCK_NB), 0, "a job's leftover program holds the lock")
    }
}

/// A switch the job runner reads from its own threads.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    init(_ on: Bool) { self.on = on }
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
