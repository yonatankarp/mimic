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
        func mesh(_ model: String = "pixal3d-sv") -> Step {
            .run(executable: "/app/mimic", arguments: ["_engine", src.path, d.appendingPathComponent("model.glb").path,
                                                       "--seed", "7", "--engine", fx.install.engine.path, "--model", model],
                 directory: nil, log: d.appendingPathComponent("pixal3d.log"))
        }
        let turned = Step.run(executable: "/app/mimic",
                              arguments: ["_prep", d.appendingPathComponent("model.glb").path,
                                          d.appendingPathComponent("mini.stl").path] + flags + ["--turn", "180"],
                              directory: nil, log: d.appendingPathComponent("prep.log"))
        func settings(_ f: (inout MiniSettings) -> Void) -> MiniSettings { var s = MiniSettings(); s.seed = 7; s.requested = sizes; f(&s); return s }
        let cases: [(String, JobKind, MiniSettings, [Step])] = [
            ("picture", .generate, settings { $0.source = .image; $0.restyle = false }, [.copyPicture(from: up, to: src), mesh(), prep]),
            ("picture, redrawn", .generate, settings { $0.source = .image; $0.restyle = true }, [.sculptPicture(from: up, seed: 7, to: src), mesh(), prep]),
            ("description", .generate, settings { $0.source = .desc; $0.desc = "a dwarf" }, [.drawCharacter(description: "a dwarf", seed: 7, to: src), mesh(), prep]),
            ("TRELLIS.2, turned to face the front", .generate, settings { $0.source = .image; $0.model = "trellis2-q8" },
             [.copyPicture(from: up, to: src), mesh("trellis2-q8"), turned]),
            ("TRELLIS.2 resize, turned too", .prep, settings { $0.model = "trellis2-q8" }, [turned]),
            ("resize", .prep, settings { _ in }, [prep]),
        ]
        for (label, kind, s, want) in cases {
            XCTAssertEqual(try Pipeline.plan(kind, folder: d, settings: s, tools: tools).map(\.step), want, label)
        }
        XCTAssertThrowsError(try Pipeline.plan(.generate, folder: d, settings: settings { $0.source = .image; $0.model = "gone" }, tools: tools)) {
            XCTAssertEqual($0 as? RequestError, .unknownModel("gone"))
        }
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

    /// A mini made before there was a choice has no `model` and is the standard one; an install
    /// with nothing chosen uses the standard model, which it already has: nothing to download.
    func testOlderMinisAndInstallsMeanTheStandardModel() throws {
        XCTAssertEqual(EngineDownload.model(MiniSettings().model), EngineDownload.standard)
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
        try fx.modelFiles()
        XCTAssertEqual(EngineDownload.standard.folder(in: fx.install).lastPathComponent, "pixal3d-sv", "existing installs keep their folder")
        defaults.removeObject(forKey: "model")
        XCTAssertTrue(EngineDownload.present(fx.install, EngineDownload.selected(defaults: defaults)),
                      "an install from before the choice would be sent to setup")
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

    func testOneJobAtATime() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); _ = try fx.mini("b")
        let slow = try fx.script("slow-prep", "sleep 5")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: slow))
        try jobs.resize(name: "a", sizes: sizes)
        XCTAssertThrowsError(try jobs.resize(name: "b", sizes: sizes)) { XCTAssertEqual($0 as? RequestError, .busy("a", .prep)) }
        XCTAssertEqual(RequestError.busy("a", .prep).description, "Mimic is still resizing A. Wait for it to finish.")
        jobs.cancel(); jobs.waitUntilDone()
    }

    /// Another Mimic (the web version, or a second app) holding the lock refuses the job.
    func testAnotherMimicHoldingTheLockRefuses() throws {
        let fx = try Fixture(); _ = try fx.mini("a")
        let fd = open(fx.install.runs.appendingPathComponent(".job.lock").path, O_CREAT | O_RDWR, 0o644)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { close(fd) }
        let jobs = JobRunner(install: fx.install, tools: fx.tools())
        XCTAssertThrowsError(try jobs.resize(name: "a", sizes: sizes)) { XCTAssertEqual($0 as? RequestError, .busy("another Mimic window")) }
        XCTAssertEqual(RequestError.busy("another Mimic window").description, "Another Mimic is making a mini right now. Wait for it to finish.")
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
