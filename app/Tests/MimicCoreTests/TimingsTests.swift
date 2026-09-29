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

    func testTooLittleHistoryUsesTheFixedFigures() {
        let e = Estimator.estimate(make, history: [record(steps: [1: 50, 2: 300, 3: 6]), record(steps: [1: 50, 2: 300, 3: 6])], machine: mac)
        XCTAssertFalse(e.learned)
        XCTAssertEqual(e, Estimator.fixed(make))
        XCTAssertEqual(e.total, 8 * 60, "Pixal3D's fixed time is the 8 minutes Settings has always said")
        XCTAssertEqual(Estimator.estimate(JobShape(job: .generate, model: "trellis2-q8", drawn: true), history: [], machine: mac).total, 12 * 60)
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
        XCTAssertEqual(e.steps, [1: 50, 2: 300, 3: 6])
        // Only two TRELLIS.2 makes: its 3D step is still the fixed one, the other steps learned.
        let t = Estimator.estimate(JobShape(job: .generate, model: "trellis2-q8", drawn: true, nozzle: "0.4", height: 32), history: history, machine: mac)
        XCTAssertFalse(t.learned)
        XCTAssertEqual(t.steps[2], Estimator.fixed(JobShape(job: .generate, model: "trellis2-q8", drawn: true)).steps[2])
        XCTAssertEqual(t.steps[1], 50)
    }

    /// A copied picture takes seconds; one Draw Things draws takes a minute. They're told apart.
    func testTheFirstStepDependsOnWhereThePictureComesFrom() {
        let drawn = (0..<3).map { _ in record(steps: [1: 70, 2: 300, 3: 6]) }
        let copied = (0..<3).map { _ in record(steps: [1: 1, 2: 300, 3: 6], source: "picture") }
        XCTAssertEqual(Estimator.estimate(make, history: drawn + copied, machine: mac).steps[1], 70)
        var shape = make; shape.drawn = false
        XCTAssertEqual(Estimator.estimate(shape, history: drawn + copied, machine: mac).steps[1], 1)
        XCTAssertEqual(Estimator.estimate(shape, history: drawn, machine: mac).steps[1], 5, "no copied pictures yet: the fixed seconds")
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
        XCTAssertEqual(small.steps, [3: 6])
        XCTAssertTrue(small.learned)
        let big = Estimator.estimate(JobShape(job: .prep, model: "pixal3d-sv", drawn: false, nozzle: "0.2", height: 100), history: history, machine: mac)
        XCTAssertEqual(big.steps, [3: 21])
        let unlike = Estimator.estimate(JobShape(job: .prep, model: "pixal3d-sv", drawn: false, nozzle: "0.6", height: 54), history: history, machine: mac)
        XCTAssertEqual(unlike.steps, [3: 13.5], "nothing similar: every print prep on this Mac")
    }

    /// Time left: the rest of this step (none once it's over its time) and every step after.
    func testTimeLeftPerStep() {
        let e = Estimate(steps: [1: 60, 2: 300, 3: 30], learned: true)
        let t0 = Date(timeIntervalSince1970: 0)
        var s = JobStatus(name: "a", kind: .generate, step: 2, started: t0)
        s.stepStarted = t0.addingTimeInterval(60)
        XCTAssertEqual(e.left(s, now: t0.addingTimeInterval(160)), 230)
        XCTAssertEqual(e.fraction(s, now: t0.addingTimeInterval(160)), 160.0 / 390)
        XCTAssertEqual(e.left(s, now: t0.addingTimeInterval(1000)), 30, "past its time, a step has nothing left, the rest still do")
        XCTAssertEqual(JobProgress.stepNote(2, of: s, estimate: e, now: t0.addingTimeInterval(160)), "about 3 minutes left")
        XCTAssertEqual(JobProgress.stepNote(3, of: s, estimate: e, now: t0.addingTimeInterval(160)), "seconds")
        XCTAssertNil(JobProgress.stepNote(1, of: s, estimate: e, now: t0.addingTimeInterval(160)), "a step that's done")
        XCTAssertEqual(JobProgress.fraction(s, estimate: e, now: t0.addingTimeInterval(1000)), 360.0 / 390,
                       "a step past its time holds the bar at its end rather than claiming the next")
    }

    func testNotesFollowTheEstimate() {
        let e = Estimate(steps: [1: 60, 2: 300, 3: 30], learned: true)
        let t0 = Date(timeIntervalSince1970: 0)
        var s = JobStatus(name: "a", kind: .generate, step: 1, started: t0)
        s.stepStarted = t0
        XCTAssertTrue(JobProgress.note(s, estimate: e, now: t0.addingTimeInterval(30)).hasPrefix("About 6 minutes left · 0:30 so far."))
        XCTAssertTrue(JobProgress.note(s, estimate: e, now: t0.addingTimeInterval(390 * 1.35 + 1)).contains("Taking longer than usual"))
        XCTAssertTrue(JobProgress.note(s, estimate: e, now: t0.addingTimeInterval(390 * 2.8 + 1)).contains("unusually slow"))
        var p = JobStatus(name: "a", kind: .prep, step: 3, started: t0)
        p.stepStarted = t0
        XCTAssertEqual(JobProgress.note(p, estimate: Estimate(steps: [3: 45], learned: false), now: t0.addingTimeInterval(12)), "Less than a minute left · 0:12 so far.")
        XCTAssertEqual(JobProgress.note(p, estimate: Estimate(steps: [3: 45], learned: false), now: t0.addingTimeInterval(100)), "Nearly done · 1:40 so far.",
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
    }

    /// Development Mimics keep their own history, so trying things never touches the real one.
    func testWhereTheHistoryLives() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(Timings.standard(environment: [:], home: home).url.path, "/Users/someone/Library/Application Support/Mimic/timings.jsonl")
        XCTAssertEqual(Timings.standard(environment: ["MIMIC_HOME": "/tmp/dev"], home: home).url.path, "/tmp/dev/timings.jsonl")
        XCTAssertEqual(Timings.standard(environment: ["MIMIC_TIMINGS": "/tmp/t.jsonl", "MIMIC_HOME": "/tmp/dev"], home: home).url.path, "/tmp/t.jsonl")
    }
}
