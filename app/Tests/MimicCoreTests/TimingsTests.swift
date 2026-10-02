import XCTest
@testable import MimicCore

/// Learned time estimates: this Mac's history of finished jobs, and what it predicts.
final class TimingsTests: XCTestCase {
    let mac = Machine(chip: "Apple M2 Max", memoryGB: 32, gpuCores: 30)
    let other = Machine(chip: "Apple M1", memoryGB: 8, gpuCores: 7)

    func record(_ job: String = "make", model: String = "pixal3d-sv", steps: [Int: Double], outcome: TimingRecord.Outcome = .finished,
                machine: Machine? = nil, source: String = "description", nozzle: String = "0.4", height: Double = 32,
                date: Date = Date()) -> TimingRecord {
        TimingRecord(date: date, version: "test", machine: machine ?? mac, job: job, mini: .character, model: model,
                     source: job == "make" ? source : nil, restyled: false, height: height, nozzle: nozzle, base: 25,
                     steps: Dictionary(uniqueKeysWithValues: steps.map { (String($0.key), $0.value) }),
                     total: steps.values.reduce(0, +), outcome: outcome)
    }

    let make = JobShape(job: .generate, model: "pixal3d-sv", drawn: true, nozzle: "0.4", height: 32)

    /// A make waiting with its picture already made (a new 3D shape, Try Again) skips drawing it,
    /// so the queue doesn't count that step (#128); one with its 3D shape too only makes the
    /// print file. Planted: every make counted all three steps, about a minute too long.
    func testAWaitingMakeCountsOnlyTheStepsItRuns() throws {
        let fx = try Fixture(), fm = FileManager.default
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        let owl = fx.install.runs.appendingPathComponent("owl")  // a new mini: nothing made yet
        try fm.createDirectory(at: owl, withIntermediateDirectories: true)
        let raven = try fx.mini("raven")
        try fm.removeItem(at: raven.appendingPathComponent("model.glb"))  // its picture only
        let crow = try fx.mini("crow")  // its picture and its 3D shape
        for d in [owl, raven, crow] { try MiniSettings.update(d) { $0.source = .desc; $0.desc = "a bird" } }
        let full = Estimator.estimate(JobShape(.generate, settings: MiniSettings.load(owl), service: .drawThings), history: [])
        let picture = try XCTUnwrap(full.steps[.picture]), printFile = try XCTUnwrap(full.steps[.print])
        let rows = jobs.queueTimes(["owl", "raven", "crow"].map { QueueEntry(name: $0, job: .generate) }, running: nil, history: [])
        XCTAssertEqual(rows.map(\.estimate.total), [full.total, full.total - picture, printFile])
        XCTAssertEqual(rows.map(\.ready), [full.total, 2 * full.total - picture, 2 * full.total - picture + printFile])
        XCTAssertEqual(jobs.estimate("raven", .generate, history: []), full, "the running job keeps its steps")
        XCTAssertEqual(Pipeline.skipped(owl), [])
    }

    /// When a mini just added should be ready, as the popover and Terminal say it (#219): its row
    /// of the queue's times, and nothing for one that isn't waiting.
    func testReadyInIsItsRowOfTheQueuesTimes() throws {
        let fx = try Fixture()
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        let queue = ["owl", "raven", "crow"].map { QueueEntry(name: $0, job: .generate) }
        let rows = jobs.queueTimes(queue, running: nil, history: [])
        XCTAssertEqual(queue.map { jobs.readyIn($0.name, queue: queue, running: nil, history: []) }, rows.map { Optional($0.ready) })
        XCTAssertNil(jobs.readyIn("dwarf", queue: queue, running: nil, history: []))
        XCTAssertNil(jobs.readyIn("owl", queue: [], running: nil, history: []))
    }

    func testTooLittleHistoryUsesTheFixedFigures() {
        let e = Estimator.estimate(make, history: [record(steps: [1: 50, 2: 300, 3: 6]), record(steps: [1: 50, 2: 300, 3: 6])], machine: mac)
        XCTAssertFalse(e.learned)
        XCTAssertEqual(e, Estimator.fixed(make))
        XCTAssertEqual(e.total, 8 * 60, "Pixal3D's fixed time is the 8 minutes Settings has always said")
        XCTAssertEqual(Estimator.estimate(JobShape(job: .generate, model: "trellis2-q8", drawn: true), history: [], machine: mac).total, 14 * 60)
        XCTAssertEqual(Estimator.estimate(JobShape(job: .prep, model: "pixal3d-sv", drawn: false), history: [], machine: mac).total, 45)
    }

    /// The median of similar finished jobs on this Mac. Failed and stopped ones, another Mac's,
    /// and another model's don't count.
    func testTheMedianOfSimilarFinishedJobsOnThisMac() {
        let history = [
            record(steps: [1: 40, 2: 290, 3: 5]),
            record(steps: [1: 60, 2: 310, 3: 7]),
            record(steps: [1: 50, 2: 300, 3: 6]),
            record(steps: [1: 50, 2: 20], outcome: .failed),
            record(steps: [1: 50, 2: 9000], outcome: .stopped),
            record(steps: [1: 1, 2: 1, 3: 1], machine: other),
            record(model: "trellis2-q8", steps: [1: 50, 2: 700, 3: 6]),
        ]
        let e = Estimator.estimate(make, history: history, machine: mac)
        XCTAssertTrue(e.learned)
        XCTAssertEqual(e.steps, [.picture: 50, .shape: 300, .print: 6])
        // Only two TRELLIS.2 makes: its 3D step is still the fixed one, the other steps learned.
        let t = Estimator.estimate(JobShape(job: .generate, model: "trellis2-q8", drawn: true, nozzle: "0.4", height: 32), history: history, machine: mac)
        XCTAssertFalse(t.learned)
        XCTAssertEqual(t.steps[.shape], Estimator.fixed(JobShape(job: .generate, model: "trellis2-q8", drawn: true)).steps[.shape])
        XCTAssertEqual(t.steps[.picture], 50)
    }

    /// A copied picture takes seconds; one Draw Things draws takes a minute. They're told apart.
    func testTheFirstStepDependsOnWhereThePictureComesFrom() {
        let drawn = (0..<3).map { _ in record(steps: [1: 70, 2: 300, 3: 6]) }
        let copied = (0..<3).map { _ in record(steps: [1: 1, 2: 300, 3: 6], source: "picture") }
        XCTAssertEqual(Estimator.estimate(make, history: drawn + copied, machine: mac).steps[.picture], 70)
        var shape = make; shape.drawn = false
        XCTAssertEqual(Estimator.estimate(shape, history: drawn + copied, machine: mac).steps[.picture], 1)
        XCTAssertEqual(Estimator.estimate(shape, history: drawn, machine: mac).steps[.picture], 5, "no copied pictures yet: the fixed seconds")
    }

    /// Draw Things takes about 20 s a picture, an online service a minute or two: each is
    /// estimated from its own (#325). Planted: both fed one median, wrong whichever you use.
    /// A copied picture is the same whichever is chosen.
    func testTheFirstStepDependsOnWhoDrawsThePicture() throws {
        func drawn(_ seconds: Double, by service: String) -> [TimingRecord] {
            (0..<3).map { _ in var r = record(steps: [1: seconds, 2: 300, 3: 6]); r.pictureService = service; return r }
        }
        let history = drawn(20, by: "drawthings") + drawn(90, by: "openai") + drawn(60, by: "bfl")
            + (0..<3).map { _ in var r = record(steps: [1: 1, 2: 300, 3: 6], source: "picture"); r.pictureService = "openai"; return r }
        var shape = make
        XCTAssertEqual(Estimator.estimate(shape, history: history, machine: mac).steps[.picture], 20)
        shape.service = .openai
        XCTAssertEqual(Estimator.estimate(shape, history: history, machine: mac).steps[.picture], 90)
        shape.service = .bfl
        XCTAssertEqual(Estimator.estimate(shape, history: history, machine: mac).steps[.picture], 60)
        shape.drawn = false
        XCTAssertEqual(Estimator.estimate(shape, history: history, machine: mac).steps[.picture], 1)

        // The queue's times ask the service Settings chose.
        let fx = try Fixture()
        try MiniSettings.update(try fx.mini("owl")) { $0.source = .desc; $0.desc = "a bird" }
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        let here = history.map { var r = $0; r.machine = .current; return r }
        XCTAssertEqual(jobs.estimate("owl", .generate, history: here).steps[.picture], 20)
        jobs.pictureService = { OpenAIImages(key: { nil }) }
        XCTAssertEqual(jobs.estimate("owl", .generate, history: here).steps[.picture], 90)
    }

    /// A history written before Mimic kept who drew each picture still reads, as Draw Things':
    /// the only way there was until online pictures (0.11.0).
    func testOlderRecordsCountAsDrawThings() throws {
        let fx = try Fixture()
        let t = Timings(url: fx.root.appendingPathComponent("timings.jsonl"))
        let line = #"{"base":25,"date":"2026-09-30T10:00:00Z","height":32,"job":"make","machine":{"chip":"Apple M2 Max","gpuCores":30,"memoryGB":32},"mini":"character","model":"pixal3d-sv","nozzle":"0.4","outcome":"finished","restyled":false,"source":"description","steps":{"1":20,"2":300,"3":6},"total":326,"version":"0.10.0"}"#
        try Data(String(repeating: line + "\n", count: 3).utf8).write(to: t.url)
        let old = t.load()
        XCTAssertEqual(old.count, 3)
        XCTAssertNil(old.first?.pictureService)
        XCTAssertEqual(Estimator.estimate(make, history: old, machine: mac).steps[.picture], 20)
        var online = make; online.service = .openai
        XCTAssertEqual(Estimator.estimate(online, history: old, machine: mac).steps[.picture], 60, "not learned from Draw Things")
    }

    /// Print prep grows with the size and a finer nozzle: a resize is estimated from ones like it
    /// (makes' step 3 counts too), else from any on this Mac.
    func testPrintPrepFromSimilarSizes() {
        let history = [
            record(steps: [1: 50, 2: 300, 3: 6], nozzle: "0.4", height: 32),
            record("resize", steps: [3: 7], nozzle: "0.4", height: 30),
            record("resize", steps: [3: 5], nozzle: "0.4", height: 36),
            record("resize", steps: [3: 20], nozzle: "0.2", height: 100),
            record("resize", steps: [3: 22], nozzle: "0.2", height: 110),
            record("resize", steps: [3: 21], nozzle: "0.2", height: 90),
        ]
        let small = Estimator.estimate(JobShape(job: .prep, model: "pixal3d-sv", drawn: false, nozzle: "0.4", height: 32), history: history, machine: mac)
        XCTAssertEqual(small.steps, [.print: 6])
        XCTAssertTrue(small.learned)
        let big = Estimator.estimate(JobShape(job: .prep, model: "pixal3d-sv", drawn: false, nozzle: "0.2", height: 100), history: history, machine: mac)
        XCTAssertEqual(big.steps, [.print: 21])
        let unlike = Estimator.estimate(JobShape(job: .prep, model: "pixal3d-sv", drawn: false, nozzle: "0.6", height: 54), history: history, machine: mac)
        XCTAssertEqual(unlike.steps, [.print: 13.5], "nothing similar: every print prep on this Mac")
    }

    /// Time left: the rest of this step (none once it's over its time) and every step after.
    func testTimeLeftPerStep() {
        let e = Estimate(steps: [.picture: 60, .shape: 300, .print: 30], learned: true)
        let t0 = Date(timeIntervalSince1970: 0)
        var s = JobStatus(name: "a", kind: .generate, step: .shape, started: t0)
        s.stepStarted = t0.addingTimeInterval(60)
        XCTAssertEqual(e.left(s, now: t0.addingTimeInterval(160)), 230)
        XCTAssertEqual(e.fraction(s, now: t0.addingTimeInterval(160)), 160.0 / 390)
        XCTAssertEqual(e.left(s, now: t0.addingTimeInterval(1000)), 30, "past its time, a step has nothing left, the rest still do")
        XCTAssertEqual(JobProgress.stepNote(.shape, of: s, estimate: e, now: t0.addingTimeInterval(160)), "about 3 minutes left")
        XCTAssertEqual(JobProgress.stepNote(.print, of: s, estimate: e, now: t0.addingTimeInterval(160)), "seconds")
        XCTAssertNil(JobProgress.stepNote(.picture, of: s, estimate: e, now: t0.addingTimeInterval(160)), "a step that's done")
        XCTAssertEqual(JobProgress.fraction(s, estimate: e, now: t0.addingTimeInterval(1000)), 360.0 / 390,
                       "a step past its time holds the bar at its end rather than claiming the next")
    }

    func testNotesFollowTheEstimate() {
        let e = Estimate(steps: [.picture: 60, .shape: 300, .print: 30], learned: true)
        let t0 = Date(timeIntervalSince1970: 0)
        var s = JobStatus(name: "a", kind: .generate, step: .picture, started: t0)
        s.stepStarted = t0
        XCTAssertTrue(JobProgress.note(s, estimate: e, now: t0.addingTimeInterval(30)).hasPrefix("About 6 minutes left · 0:30 so far."))
        XCTAssertTrue(JobProgress.note(s, estimate: e, now: t0.addingTimeInterval(390 * 1.35 + 1)).contains("Taking longer than usual"))
        XCTAssertTrue(JobProgress.note(s, estimate: e, now: t0.addingTimeInterval(390 * 2.8 + 1)).contains("unusually slow"))
        var p = JobStatus(name: "a", kind: .prep, step: .print, started: t0)
        p.stepStarted = t0
        XCTAssertEqual(JobProgress.note(p, estimate: Estimate(steps: [.print: 45], learned: false), now: t0.addingTimeInterval(12)), "Less than a minute left · 0:12 so far.")
        XCTAssertEqual(JobProgress.note(p, estimate: Estimate(steps: [.print: 45], learned: false), now: t0.addingTimeInterval(100)), "Nearly done · 1:40 so far.",
                       "a short job a minute over isn't called slow")
        XCTAssertEqual(JobProgress.about(8 * 60), "about 8 minutes")
        XCTAssertEqual(JobProgress.about(80 * 60), "about 1 hour 20 minutes")
        XCTAssertEqual(JobProgress.about(60), "about a minute")
    }

    /// One line per job, the newest kept past the cap.
    func testTheHistoryIsCapped() throws {
        let fx = try Fixture()
        let t = Timings(url: fx.root.appendingPathComponent("timings.jsonl"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        t.append((0..<(Timings.cap - 5)).map { record(steps: [3: 1], date: t0.addingTimeInterval(Double($0))) })
        for k in 0..<10 { t.append([record(steps: [3: 1], date: t0.addingTimeInterval(Double(Timings.cap + k)))]) }
        let all = t.load()
        XCTAssertEqual(all.count, Timings.cap)
        XCTAssertEqual(all.last?.date, t0.addingTimeInterval(Double(Timings.cap + 9)))
        XCTAssertEqual(all.first?.date, t0.addingTimeInterval(5), "the oldest go first")
        t.clear()
        XCTAssertEqual(t.load(), [])
        t.seedIfNeeded(runs: fx.install.runs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.url.path))
    }

    /// The history is written beside itself and put in its place, so a crash halfway never
    /// leaves it cut short (#179), and jobs finishing together all get their line in.
    func testTheHistoryIsReplacedWholeAndAppendsTakeTurns() throws {
        let fx = try Fixture()
        let t = Timings(url: fx.root.appendingPathComponent("timings.jsonl"))
        t.append([record(steps: [3: 1])])
        func inode() throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: t.url.path)[.systemFileNumber] as? Int) }
        let before = try inode()
        t.append([record(steps: [3: 2])])
        XCTAssertNotEqual(try inode(), before, "written in place")
        XCTAssertEqual(t.load().map(\.total), [1, 2])
        let one = record(steps: [3: 1])
        DispatchQueue.concurrentPerform(iterations: 30) { _ in t.append([one]) }
        XCTAssertEqual(t.load().count, 32)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fx.root.path).filter { $0.hasPrefix("timings") }.sorted(),
                       ["timings.jsonl", "timings.jsonl.lock"])
    }

    /// Every job a runner finishes is recorded, with how long each step took and how it ended.
    func testEveryJobIsRecorded() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let t = Timings(url: fx.root.appendingPathComponent("timings.jsonl"))
        let ok = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "sleep 0.3")), timings: t, version: "0.5.0")
        try ok.resize(name: "a", sizes: Sizes(height: "54", nozzle: "0.2"))
        ok.waitUntilDone()
        let bad = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), timings: t)
        try bad.resize(name: "a", sizes: Sizes(height: "54", nozzle: "0.2"))
        bad.waitUntilDone()
        let r = t.load()
        XCTAssertEqual(r.map(\.outcome), [.finished, .failed])
        XCTAssertEqual(r[0].job, "resize")
        XCTAssertEqual(r[0].version, "0.5.0")
        XCTAssertEqual(r[0].nozzle, "0.2")
        XCTAssertEqual(r[0].height, 54)
        XCTAssertEqual(r[0].machine, Machine.current)
        XCTAssertGreaterThanOrEqual(r[0].steps["3"] ?? 0, 0.3)
        XCTAssertFalse(Machine.current.chip.isEmpty)
        XCTAssertGreaterThan(Machine.current.memoryGB, 0)
    }

    /// Past minis seed the history, but only when their files' times can be trusted.
    func testImportingPastMinis() throws {
        let fx = try Fixture()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func made(_ name: String, log: String = "[1/3] Getting the picture ready\n[2/3] Building the 3D shape\n[3/3] Making the print-ready file\n",
                  engineBorn: Double = 60, resizedAfter: Bool = false) throws {
            let d = try fx.mini(name)
            try MiniSettings.update(d) { $0.source = .desc; $0.requested = Sizes(height: "32", nozzle: "0.2") }
            let fm = FileManager.default
            try log.write(to: d.appendingPathComponent("generate.job.log"), atomically: true, encoding: .utf8)
            fm.createFile(atPath: d.appendingPathComponent("pixal3d.log").path, contents: nil)
            func stamp(_ f: String, born: Double, changed: Double) throws {
                try fm.setAttributes([.creationDate: t0.addingTimeInterval(born), .modificationDate: t0.addingTimeInterval(changed)],
                                     ofItemAtPath: d.appendingPathComponent(f).path)
            }
            try stamp("generate.job.log", born: 0, changed: 360)
            try stamp("pixal3d.log", born: engineBorn, changed: 359)
            try stamp("\(name).stl", born: 366, changed: 366)
            if resizedAfter {
                fm.createFile(atPath: d.appendingPathComponent("prep.job.log").path, contents: nil)
                try stamp("prep.job.log", born: 900, changed: 900)
            }
        }
        try made("good")
        try made("old-format", log: "[2/3] mesh (Pixal3D, ~7 min)\n[3/3] print prep\n")
        try made("retried", engineBorn: -500)
        try made("resized", resizedAfter: true)
        try made("unfinished", log: "[1/3] Getting the picture ready\n[2/3] Building the 3D shape\n")
        let found = Timings.importPast(runs: fx.install.runs, machine: mac)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.steps, ["1": 60, "2": 300, "3": 6])
        XCTAssertEqual(found.first?.source, "description")
        XCTAssertEqual(found.first?.nozzle, "0.2")
        XCTAssertEqual(found.first?.imported, true)

        let t = Timings(url: fx.root.appendingPathComponent("timings.jsonl"))
        t.seedIfNeeded(runs: fx.install.runs, machine: mac)
        XCTAssertEqual(t.load().count, 1)
        t.clear()
        t.seedIfNeeded(runs: fx.install.runs, machine: mac)
        XCTAssertEqual(t.load().count, 0, "Clear must not bring the imported minis back")

        // The app and `mimic make` starting together on a new Mac both seed, while a job
        // finishes (#333). Planted: the check and the import were outside the lock, so the minis
        // went in twice or the second seed's clear wiped the finished job.
        for _ in 0..<20 {
            try FileManager.default.removeItem(at: t.url)
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                t.seedIfNeeded(runs: fx.install.runs, machine: mac)  // each Mimic seeds as it starts
                if i == 0 { t.append([record(steps: [3: 1])]) }
            }
            let all = t.load()
            XCTAssertEqual(all.filter { $0.imported == true }.count, 1, "seeded once")
            XCTAssertEqual(all.filter { $0.imported == nil }.count, 1, "the finished job kept")
        }
    }

    /// Development Mimics keep their own history, so trying things never touches the real one.
    func testWhereTheHistoryLives() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(Timings.standard(environment: [:], home: home).url.path, "/Users/someone/Library/Application Support/Mimic/timings.jsonl")
        XCTAssertEqual(Timings.standard(environment: ["MIMIC_HOME": "/tmp"], home: home).url.path, "/tmp/timings.jsonl")
        XCTAssertEqual(Timings.standard(environment: ["MIMIC_TIMINGS": "/tmp/t.jsonl", "MIMIC_HOME": "/tmp"], home: home).url.path, "/tmp/t.jsonl")
        // Read as the minis and the queue are (#333). Planted: a mistyped folder kept the history
        // somewhere of its own while Mimic used the real minis and queue.
        XCTAssertEqual(Timings.standard(environment: ["MIMIC_HOME": "/tmp/no-such-mimic"], home: home).url.path,
                       "/Users/someone/Library/Application Support/Mimic/timings.jsonl")
        let tilde = Timings.standard(environment: ["MIMIC_HOME": "~"], home: home).url.path
        XCTAssertEqual(tilde, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("timings.jsonl").path)
    }
}
