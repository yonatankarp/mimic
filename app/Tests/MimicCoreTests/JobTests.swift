import XCTest
@testable import MimicCore

/// Ported from tests/test_settings.py and tests/test_cancel.py (job half).
final class JobTests: XCTestCase {
    let sizes = Sizes(height: "100", base: "40", nozzle: "0.4")

    func testAFinishedRunRecordsWhatItMade() throws {
        let fx = try Fixture(); _ = try fx.mini("dwarf")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        try jobs.resize(name: "dwarf", sizes: sizes)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.succeeded, true)
        XCTAssertEqual(MiniSettings.load(fx.install.runs.appendingPathComponent("dwarf")).made, sizes)
    }

    func testAFailedRunRecordsNothing() throws {
        let fx = try Fixture(); let d = try fx.mini("dwarf")
        try MiniSettings.update(d) { $0.made = Sizes(height: "32") }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"))
        try jobs.resize(name: "dwarf", sizes: sizes)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.exit, 1)
        XCTAssertEqual(MiniSettings.load(d).made, Sizes(height: "32"), "a failure overwrote 'made'")
    }

    func testTryAgainRebuildsTheSameJob() throws {
        let fx = try Fixture()
        let d = fx.install.runs.appendingPathComponent("mini")
        let tools = fx.tools(mimic: "/app/mimic")
        let src = d.appendingPathComponent("source.png"), up = d.appendingPathComponent("upload.img")
        let flags = ["--height", "100.0", "--base", "40.0", "--nozzle", "0.4"]
        let prep = Step.run(executable: "/app/mimic",
                            arguments: ["_prep", d.appendingPathComponent("model.glb").path,
                                        d.appendingPathComponent("mini.stl").path] + flags,
                            directory: nil, log: d.appendingPathComponent("prep.log"))
        func mesh(_ model: String = "trellis2-q8") -> Step {
            .run(executable: "/app/mimic", arguments: ["_engine", src.path, d.appendingPathComponent("model.glb").path,
                                                       "--seed", "7", "--engine", fx.install.engine.path, "--model", model],
                 directory: nil, log: d.appendingPathComponent("pixal3d.log"))
        }
        let turned = Step.run(executable: "/app/mimic",
                              arguments: ["_prep", d.appendingPathComponent("model.glb").path,
                                          d.appendingPathComponent("mini.stl").path] + flags + ["--turn", "180"],
                              directory: nil, log: d.appendingPathComponent("prep.log"))
        func settings(_ f: (inout MiniSettings) -> Void) -> MiniSettings { var s = MiniSettings(); s.seed = 7; s.requested = sizes; s.model = "trellis2-q8"; f(&s); return s }
        let cases: [(String, JobKind, MiniSettings, [Step])] = [
            ("picture", .generate, settings { $0.source = .image; $0.restyle = false }, [.copyPicture(from: up, to: src), mesh(), turned]),
            ("picture, redrawn", .generate, settings { $0.source = .image; $0.restyle = true }, [.sculptPicture(from: up, seed: 7, to: src), mesh(), turned]),
            ("description", .generate, settings { $0.source = .desc; $0.desc = "a dwarf" }, [.drawCharacter(description: "a dwarf", seed: 7, to: src), mesh(), turned]),
            ("Pixal3D, not turned", .generate, settings { $0.source = .image; $0.model = "pixal3d-sv" },
             [.copyPicture(from: up, to: src), mesh("pixal3d-sv"), prep]),
            ("Pixal3D resize, not turned either", .prep, settings { $0.model = "pixal3d-sv" }, [prep]),
            ("resize", .prep, settings { _ in }, [turned]),
        ]
        for (label, kind, s, want) in cases {
            XCTAssertEqual(try Pipeline.plan(kind, folder: d, settings: s, tools: tools).map(\.step), want, label)
        }
        XCTAssertThrowsError(try Pipeline.plan(.generate, folder: d, settings: settings { $0.source = .image; $0.model = "gone" }, tools: tools)) {
            XCTAssertEqual($0 as? RequestError, .unknownModel("gone"))
        }
    }

    /// Try Again starts at the step that failed (#79): a picture already made isn't drawn again,
    /// and a new Make in a failed attempt's folder doesn't reuse that attempt's picture.
    func testTryAgainStartsAtTheStepThatFailed() throws {
        let fx = try Fixture()
        try fx.modelFiles()
        let picture = fx.root.appendingPathComponent("pic.png")
        FileManager.default.createFile(atPath: picture.path, contents: Data([1]))
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        let d = fx.install.runs.appendingPathComponent("mini")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let src = d.appendingPathComponent("source.png")
        try MiniSettings.update(d) { $0.source = .image }  // a failed attempt, with the picture it drew
        FileManager.default.createFile(atPath: src.path, contents: Data("old".utf8))
        try jobs.make(name: "mini", picture: .image(picture), restyle: true, seed: 1, sizes: sizes, model: EngineDownload.standard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path), "a new Make draws its own picture")
        jobs.waitUntilDone()
        let settings = MiniSettings.load(d), tools = fx.tools(mimic: "/app/mimic")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: settings, tools: tools).map(\.number), [1, 2, 3])
        FileManager.default.createFile(atPath: src.path, contents: Data([1]))  // step 1 finished, step 2 failed
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: settings, tools: tools).map(\.number), [2, 3], "not drawn again")
    }

    /// A new mini records the model it's made with, so Try Again uses that one and not whatever
    /// is in use by then; a model that isn't downloaded is refused before anything is written.
    func testTheModelIsRecordedAndMustBeDownloaded() throws {
        let fx = try Fixture()
        let picture = fx.root.appendingPathComponent("pic.png")
        FileManager.default.createFile(atPath: picture.path, contents: Data([1]))
        let other = EngineDownload.catalogue.last!
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"))
        XCTAssertThrowsError(try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: other)) {
            XCTAssertEqual($0 as? RequestError, .modelNotDownloaded(other.name))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("mini").path), "a refused mini left a folder")

        try fx.modelFiles(other)
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: other)
        jobs.waitUntilDone()
        let folder = fx.install.runs.appendingPathComponent("mini")
        XCTAssertEqual(MiniSettings.load(folder).model, other.id)

        // Removed since: Try Again says so at once instead of failing minutes into the 3D step.
        try FileManager.default.removeItem(at: other.folder(in: fx.install))
        XCTAssertThrowsError(try jobs.retry(name: "mini")) { XCTAssertEqual($0 as? RequestError, .modelNotDownloaded(other.name)) }
        try fx.modelFiles(other)
        XCTAssertNoThrow(try jobs.retry(name: "mini"))
        jobs.waitUntilDone()
    }

    /// A mini with no `model` was made before 0.4.0, so with Pixal3D (not the standard model,
    /// TRELLIS.2, which would turn it round on Resize); an install with nothing chosen uses the
    /// standard model and, once that is downloaded, has nothing more to download.
    func testOlderMinisMeanPixal3DAndInstallsTheStandardModel() throws {
        XCTAssertEqual(EngineDownload.model(MiniSettings().model)?.id, "pixal3d-sv")
        let old = try JSONDecoder().decode(MiniSettings.self, from: Data(#"{"requested": {"height": "32"}, "seed": 3}"#.utf8))
        XCTAssertNil(old.model)
        let suite = "mimic-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(EngineDownload.selected(defaults: defaults), EngineDownload.standard)
        defaults.set("no-such-model", forKey: "model")
        XCTAssertEqual(EngineDownload.selected(defaults: defaults), EngineDownload.standard, "an unknown choice must still make minis")
        defaults.set(EngineDownload.catalogue.last!.id, forKey: "model")
        XCTAssertEqual(EngineDownload.selected(defaults: defaults), EngineDownload.catalogue.last!)

        let fx = try Fixture()
        try FileManager.default.createDirectory(at: fx.install.engine, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: fx.install.trellisCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.install.trellisCLI.path)
        try FileManager.default.copyItem(at: fx.install.trellisCLI, to: fx.install.drawThingsCLI)
        try fx.modelFiles()
        XCTAssertEqual(EngineDownload.standard.folder(in: fx.install).lastPathComponent, "trellis2-q8", "the standard model's folder")
        defaults.removeObject(forKey: "model")
        XCTAssertTrue(EngineDownload.present(fx.install, EngineDownload.selected(defaults: defaults)),
                      "an install with nothing chosen would be sent to setup")
    }

    /// An object mini: the object prompts, and print prep sizes it by its longest side and
    /// stands it on its whole bottom, on every route Try Again and Resize take.
    func testObjectMinisPlanObjectStepsAndPrepFlags() throws {
        let fx = try Fixture()
        let d = fx.install.runs.appendingPathComponent("pot")
        let src = d.appendingPathComponent("source.png"), up = d.appendingPathComponent("upload.img")
        func settings(_ f: (inout MiniSettings) -> Void) -> MiniSettings {
            var s = MiniSettings(); s.seed = 7; s.kind = .object; s.model = "trellis2-q8"; s.requested = Sizes(height: "80", nozzle: "0.4", noBase: true); f(&s); return s
        }
        func plan(_ kind: JobKind, _ s: MiniSettings) throws -> [Step] { try Pipeline.plan(kind, folder: d, settings: s, tools: fx.tools(mimic: "/app/mimic")).map(\.step) }
        let prepArgs = ["_prep", d.appendingPathComponent("model.glb").path, d.appendingPathComponent("pot.stl").path,
                        "--height", "80.0", "--nozzle", "0.4", "--no-base", "--fit", "longest", "--ground", "bottom", "--turn", "180"]
        guard case let .run(_, args, _, _) = try plan(.prep, settings { _ in })[0] else { return XCTFail("resize runs print prep") }
        XCTAssertEqual(args, prepArgs)
        // A floor on its base is laid out by the mini's number, so Try Again lays it the same way.
        guard case let .run(_, floor, _, _) = try plan(.prep, settings { $0.requested = Sizes(height: "80", base: "40", nozzle: "0.4", style: .wood) })[0]
        else { return XCTFail("resize runs print prep") }
        XCTAssertEqual(Array(floor.drop { $0 != "--base-style" }), ["--base-style", "wood", "--fit", "longest", "--ground", "bottom", "--turn", "180", "--base-seed", "7"])
        XCTAssertEqual(try plan(.generate, settings { $0.source = .desc; $0.desc = "a teapot" })[0], .drawObject(description: "a teapot", seed: 7, to: src))
        XCTAssertEqual(try plan(.generate, settings { $0.source = .image; $0.restyle = true })[0], .sculptObject(from: up, seed: 7, to: src))
        XCTAssertEqual(try plan(.generate, settings { $0.source = .image; $0.restyle = false })[0], .copyPicture(from: up, to: src))
    }

    /// make records the kind every time: a folder left by a failed object attempt doesn't turn
    /// the next character into an object, and a character's settings.json has no kind.
    func testMakeRecordsTheKind() throws {
        let fx = try Fixture()
        let picture = fx.root.appendingPathComponent("pic.png")
        FileManager.default.createFile(atPath: picture.path, contents: Data([1]))
        let d = fx.install.runs.appendingPathComponent("mini")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        try fx.modelFiles()
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, kind: .object, model: EngineDownload.standard)
        jobs.waitUntilDone()
        XCTAssertEqual(MiniSettings.load(d).kind, .object)
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        jobs.waitUntilDone()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertNil(json["kind"])
    }

    /// Object mode and the model choice together: the plan passes both the object's flags and
    /// TRELLIS.2's turn; a character with TRELLIS.2 gets the turn alone (as before object mode)
    /// and an object with Pixal3D gets the object flags alone (as before the choice).
    func testObjectFlagsAndTheModelsTurnCompose() throws {
        let fx = try Fixture()
        let d = fx.install.runs.appendingPathComponent("mini")
        func prepArgs(_ f: (inout MiniSettings) -> Void) throws -> [String] {
            var s = MiniSettings(); s.source = .image; s.seed = 7; s.requested = sizes; f(&s)
            guard case let .run(_, args, _, _) = try Pipeline.plan(.generate, folder: d, settings: s, tools: fx.tools(mimic: "/app/mimic")).last!.step
            else { XCTFail(); return [] }
            return Array(args.dropFirst(3))
        }
        let base = try sizes.flags()
        let object = ["--fit", "longest", "--ground", "bottom"], turn = ["--turn", "180"]
        XCTAssertEqual(try prepArgs { $0.kind = .object; $0.model = "trellis2-q8" }, base + object + turn)
        XCTAssertEqual(try prepArgs { $0.model = "trellis2-q8" }, base + turn, "a TRELLIS.2 character changed")
        XCTAssertEqual(try prepArgs { $0.kind = .object; $0.model = "pixal3d-sv" }, base + object, "a Pixal3D object changed")
        XCTAssertEqual(try prepArgs { $0.model = "pixal3d-sv" }, base, "a Pixal3D character changed")
        XCTAssertEqual(try prepArgs { _ in }, base, "a mini with no model recorded is Pixal3D's, so not turned")
    }

    /// Kind, model and the helper's original description all survive a round trip through
    /// settings.json, and a mini without them reads as a Pixal3D character.
    func testKindModelAndDescriptionRoundTrip() throws {
        let fx = try Fixture()
        let d = fx.install.runs.appendingPathComponent("mini")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try MiniSettings.update(d) { $0.kind = .object; $0.model = "trellis2-q8"; $0.desc = "a teapot, rounded"; $0.descOriginal = "teapot" }
        let s = MiniSettings.load(d)
        XCTAssertEqual(s.kind, .object)
        XCTAssertEqual(s.model, "trellis2-q8")
        XCTAssertEqual(s.desc, "a teapot, rounded")
        XCTAssertEqual(s.descOriginal, "teapot")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertEqual(json["kind"] as? String, "object")
        XCTAssertEqual(json["model"] as? String, "trellis2-q8")
        XCTAssertEqual(json["descOriginal"] as? String, "teapot")
        XCTAssertFalse(MiniSettings().isObject)
        XCTAssertEqual(EngineDownload.model(MiniSettings().model)?.id, "pixal3d-sv")
    }

    /// prep.log is appended to, so a warning from an earlier run must not follow the mini around.
    func testFragileIsThisRunsWarningOnly() throws {
        let fx = try Fixture(); let d = try fx.mini("dwarf")
        try "mini_prep: WARNING thin parts\n".write(to: d.appendingPathComponent("prep.log"), atomically: true, encoding: .utf8)
        let quiet = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        try quiet.resize(name: "dwarf", sizes: sizes); quiet.waitUntilDone()
        XCTAssertEqual(quiet.status?.fragile, false)
        let warns = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "echo 'mini_prep: WARNING thin parts'")))
        try warns.resize(name: "dwarf", sizes: sizes); warns.waitUntilDone()
        XCTAssertEqual(warns.status?.fragile, true)
    }

    /// A part print prep left out, or an object that needs a base, is said in its own words,
    /// beside the generic fragile line that the footprint warning still gets.
    func testAPartLeftOutIsSaidInItsOwnWords() throws {
        let fx = try Fixture(); _ = try fx.mini("elf")
        let part = "A part came out separate from the figure (about 30 mm long) and was left out."
        let stand = "It needs a base to stand."
        let one = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "echo '\(Prep.partWarning)\(part)'; echo '\(Prep.standWarning)\(stand)'")))
        try one.resize(name: "elf", sizes: sizes); one.waitUntilDone()
        XCTAssertEqual(one.status?.notes, [part, stand])
        XCTAssertEqual(one.status?.fragile, false)
        let both = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep2", "echo 'mini_prep: WARNING footprint'; echo '\(Prep.partWarning)\(part)'")))
        try both.resize(name: "elf", sizes: sizes); both.waitUntilDone()
        XCTAssertEqual(both.status?.notes, [part])
        XCTAssertEqual(both.status?.fragile, true)
    }

    /// Stop during the 3D step: the job and its child end, it reads as stopped, and the
    /// half-made mini goes to the Trash.
    func testStopEndsTheJobAndTrashesAHalfMadeMini() throws {
        let fx = try Fixture()
        let childFile = fx.root.appendingPathComponent("child.pid").path
        let engine = try fx.script("fake-engine", "sleep 60 & echo $! > \(childFile); wait")
        let picture = fx.root.appendingPathComponent("pic.png")
        FileManager.default.createFile(atPath: picture.path, contents: Data([1]))
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: engine), trash: { spy($0) })
        try fx.modelFiles()
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        var child: pid_t = 0
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: childFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { child = p; break }
            usleep(50_000)
        }
        XCTAssertEqual(jobs.status?.step, 2)
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.canceled, true)
        XCTAssertNotEqual(jobs.status?.exit, 0)
        usleep(200_000)
        XCTAssertNotEqual(kill(child, 0), 0, "Stop left the 3D engine's child running")
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["mini"])
    }

    /// A second job while one runs waits its turn instead of being refused, then runs.
    func testOneJobAtATime() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); _ = try fx.mini("b")
        let slow = try fx.script("slow-prep", "sleep 1")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: slow))
        XCTAssertNil(try jobs.resize(name: "a", sizes: sizes), "nothing was running: it starts at once")
        XCTAssertEqual(try jobs.resize(name: "b", sizes: sizes), 1, "one ahead of it: the running one")
        XCTAssertEqual(jobs.status?.name, "a")
        XCTAssertThrowsError(try jobs.resize(name: "a", sizes: sizes)) { XCTAssertEqual($0 as? RequestError, .busy("a", .prep)) }
        XCTAssertThrowsError(try jobs.resize(name: "b", sizes: sizes)) { XCTAssertEqual($0 as? RequestError, .queued("b")) }
        XCTAssertEqual(RequestError.busy("a", .prep).description, "Mimic is still resizing A. Wait for it to finish.")
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.name, "b", "the waiting job ran after the first")
        XCTAssertEqual(jobs.status?.succeeded, true)
        XCTAssertEqual(jobs.queue.entries(), [])
    }

    /// Another Mimic holding the lock: the job waits in the queue for it, and starts once that
    /// Mimic is gone and anyone looks again.
    func testAnotherMimicHoldingTheLockQueues() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let fd = open(fx.install.runs.appendingPathComponent(".job.lock").path, O_CREAT | O_RDWR, 0o644)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        XCTAssertEqual(try jobs.resize(name: "a", sizes: sizes), 1)
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["a"])
        jobs.pump()
        XCTAssertNil(jobs.status, "started while another Mimic held the lock")
        close(fd)  // that Mimic quit (or crashed)
        jobs.pump()
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.succeeded, true)
        XCTAssertEqual(jobs.queue.entries(), [])
    }

    /// A job orphaned by a crash is stopped on the next launch; a stale record naming a pid that
    /// now belongs to something else is left alone.
    func testLeftoverJobsAreStoppedOnlyWhenTheyAreReallyOurs() throws {
        let fx = try Fixture()
        let orphan = try GroupProcess(executable: "/bin/sleep", arguments: ["60"], environment: [:])
        Leftover.record(pid: orphan.pid, runs: fx.install.runs)
        XCTAssertTrue(Leftover.stop(fx.install.runs))
        XCTAssertEqual(orphan.wait(), -15)

        let unrelated = try GroupProcess(executable: "/bin/sleep", arguments: ["60"], environment: [:])
        try "\(unrelated.pid) 12345".write(to: Leftover.file(fx.install.runs), atomically: true, encoding: .utf8)
        XCTAssertFalse(Leftover.stop(fx.install.runs), "a pid whose start time doesn't match must not be stopped")
        XCTAssertEqual(kill(unrelated.pid, 0), 0)
        unrelated.terminateGroup(); unrelated.wait()
    }
}
