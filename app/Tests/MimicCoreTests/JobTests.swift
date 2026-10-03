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
        XCTAssertEqual(MiniSettings.load(fx.install.runs.appendingPathComponent("dwarf")).facesFront, true,
                       "its print file faces the slicer's front, as every one made now does (#275)")
    }

    func testAFailedRunRecordsNothing() throws {
        let fx = try Fixture(); let d = try fx.mini("dwarf")
        try MiniSettings.update(d) { $0.made = Sizes(height: "32") }
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"))
        try jobs.resize(name: "dwarf", sizes: sizes)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.exit, 1)
        XCTAssertEqual(MiniSettings.load(d).made, Sizes(height: "32"), "a failure overwrote 'made'")
        XCTAssertNil(MiniSettings.load(d).facesFront, "a failure left the old print file, which may face away")
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
            ("picture", .generate, settings { $0.source = .image; $0.restyle = false }, [.copyPicture(from: up, to: src), mesh(), prep]),
            ("picture, redrawn", .generate, settings { $0.source = .image; $0.restyle = true }, [.sculptPicture(from: up, seed: 7, to: src), mesh(), prep]),
            ("description", .generate, settings { $0.source = .desc; $0.desc = "a dwarf" }, [.drawCharacter(description: "a dwarf", seed: 7, to: src), mesh(), prep]),
            ("Pixal3D, turned", .generate, settings { $0.source = .image; $0.model = "pixal3d-sv" },
             [.copyPicture(from: up, to: src), mesh("pixal3d-sv"), turned]),
            ("Pixal3D resize, turned too", .prep, settings { $0.model = "pixal3d-sv" }, [turned]),
            ("resize", .prep, settings { _ in }, [prep]),
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
        let picture = try fx.picture()
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
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: settings, tools: tools).map(\.number), [.picture, .shape, .print])
        FileManager.default.createFile(atPath: src.path, contents: Data([1]))  // step 1 finished, step 2 failed
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: settings, tools: tools).map(\.number), [.shape, .print], "not drawn again")
    }

    /// A finished mini whose model.glb is gone isn't a failed attempt (#308): a Make with its name
    /// is refused, and its settings, pictures and print file are left exactly as they were.
    func testAMakeNeverOverwritesAFinishedMiniWithoutItsModel() throws {
        let fx = try Fixture(), fm = FileManager.default
        try fx.modelFiles()
        let picture = try fx.picture()
        let d = try fx.mini("raven")
        try fm.removeItem(at: d.appendingPathComponent(Mini.modelFile))
        fm.createFile(atPath: d.appendingPathComponent("upload.img").path, contents: Data("upload".utf8))
        try MiniSettings.update(d) { s in
            s.source = .desc; s.desc = "a raven"; s.seed = 7; s.created = Date(timeIntervalSince1970: 1); s.made = sizes
        }
        func files() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for f in try fm.contentsOfDirectory(atPath: d.path) { out[f] = try Data(contentsOf: d.appendingPathComponent(f)) }
            return out
        }
        let before = try files()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        XCTAssertThrowsError(try jobs.make(name: "raven", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard)) {
            XCTAssertEqual($0 as? RequestError, .nameTaken("raven"))
        }
        jobs.waitUntilDone()
        XCTAssertNil(jobs.status, "nothing ran")
        XCTAssertEqual(try files(), before, "the finished mini was changed")
    }

    /// A mini waiting for its picture to be checked (#156) isn't a failed attempt either (#380):
    /// a Make with its name in the same place is refused, and its picture and settings are kept.
    func testAMakeNeverReplacesAPictureWaitingToBeChecked() throws {
        let fx = try Fixture(), fm = FileManager.default
        try fx.modelFiles()
        let picture = try fx.picture()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        try jobs.make(name: "knight", picture: .image(picture), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard,
                      checkPicture: true)
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.outcome, .pictureReady)
        let d = try XCTUnwrap(Gallery.folder(fx.install.runs, "knight"))
        func files() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for f in try fm.contentsOfDirectory(atPath: d.path) { out[f] = try Data(contentsOf: d.appendingPathComponent(f)) }
            return out
        }
        let before = try files(), status = jobs.status
        XCTAssertNotNil(before["source.png"], "its picture is made")
        XCTAssertThrowsError(try jobs.make(name: "knight", picture: .image(picture), restyle: false, seed: 1, sizes: sizes,
                                           model: EngineDownload.standard)) {
            XCTAssertEqual($0 as? RequestError, .nameTaken("knight"))
        }
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status, status, "nothing ran")
        XCTAssertEqual(jobs.queue.entries(), [])
        XCTAssertEqual(try files(), before, "the picture waiting to be checked was changed")
    }

    /// A job with the fixture's tools never reaches the real Draw Things (#140): on a Mac that
    /// has it, the test above drew a real picture for minutes and then saw the wrong plan.
    func testTheFixtureNeverReachesTheRealDrawThings() throws {
        let fx = try Fixture()
        let dt = JobRunner(install: fx.install, tools: fx.tools()).drawThings
        XCTAssertNil(dt.cli, "would run Mimic's own draw-things-cli")
        XCTAssertEqual(dt.base.port, 9, "would ask the real Draw Things")
        XCTAssertFalse(dt.app.enabled(), "could open the real Draw Things")
        XCTAssertNil(dt.app.open())
    }

    /// Every job in the tests takes the fixture's tools or names its own Draw Things: one made
    /// without either reaches the real one.
    func testNoTestJobReachesTheRealDrawThings() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var leaks: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let lines = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8).components(separatedBy: .newlines)
            for (i, line) in lines.enumerated() where line.contains("JobRunner(") && !line.contains(".tools(") && !line.contains("drawThings:") {
                leaks.append("\(file):\(i + 1)")
            }
        }
        XCTAssertEqual(leaks, [], "give these jobs the fixture's tools")
    }

    /// A new mini records the model it's made with, so Try Again uses that one and not whatever
    /// is in use by then; a model that isn't downloaded is refused before anything is written.
    func testTheModelIsRecordedAndMustBeDownloaded() throws {
        let fx = try Fixture()
        let picture = try fx.picture()
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
                        "--height", "80.0", "--nozzle", "0.4", "--no-base", "--fit", "longest", "--ground", "bottom"]
        guard case let .run(_, args, _, _) = try plan(.prep, settings { _ in })[0] else { return XCTFail("resize runs print prep") }
        XCTAssertEqual(args, prepArgs)
        // A floor on its base is laid out by the mini's number, so Try Again lays it the same way.
        guard case let .run(_, floor, _, _) = try plan(.prep, settings { $0.requested = Sizes(height: "80", base: "40", nozzle: "0.4", style: .wood) })[0]
        else { return XCTFail("resize runs print prep") }
        XCTAssertEqual(Array(floor.drop { $0 != "--base-style" }), ["--base-style", "wood", "--fit", "longest", "--ground", "bottom", "--base-seed", "7"])
        XCTAssertEqual(try plan(.generate, settings { $0.source = .desc; $0.desc = "a teapot" })[0], .drawObject(description: "a teapot", seed: 7, to: src))
        XCTAssertEqual(try plan(.generate, settings { $0.source = .image; $0.restyle = true })[0], .sculptObject(from: up, seed: 7, to: src))
        XCTAssertEqual(try plan(.generate, settings { $0.source = .image; $0.restyle = false })[0], .copyPicture(from: up, to: src))
    }

    /// make records the kind every time: a folder left by a failed object attempt doesn't turn
    /// the next character into an object, and a character's settings.json has no kind.
    func testMakeRecordsTheKind() throws {
        let fx = try Fixture()
        let picture = try fx.picture()
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
    /// Pixal3D's turn; a character with Pixal3D gets the turn alone and an object with TRELLIS.2
    /// the object flags alone.
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
        XCTAssertEqual(try prepArgs { $0.kind = .object; $0.model = "pixal3d-sv" }, base + object + turn)
        XCTAssertEqual(try prepArgs { $0.model = "pixal3d-sv" }, base + turn, "a Pixal3D character changed")
        XCTAssertEqual(try prepArgs { $0.kind = .object; $0.model = "trellis2-q8" }, base + object, "a TRELLIS.2 object changed")
        XCTAssertEqual(try prepArgs { $0.model = "trellis2-q8" }, base, "a TRELLIS.2 character changed")
        XCTAssertEqual(try prepArgs { _ in }, base + turn, "a mini with no model recorded is Pixal3D's, so turned")
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

    /// An earlier run's report (or warning in prep.log, which is appended to) must not follow
    /// the mini around.
    func testFragileIsThisRunsWarningOnly() throws {
        let fx = try Fixture(); let d = try fx.mini("dwarf")
        try "mini_prep: WARNING thin parts\n".write(to: d.appendingPathComponent("prep.log"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(PrepReport(warnings: [.init(.footprint, "thin parts")])).write(to: d.appendingPathComponent("prep-result.json"))
        let quiet = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        try quiet.resize(name: "dwarf", sizes: sizes); quiet.waitUntilDone()
        XCTAssertEqual(quiet.status?.fragile, false)
        let warns = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.prep("prep", PrepReport(warnings: [.init(.footprint, "thin parts")]))))
        try warns.resize(name: "dwarf", sizes: sizes); warns.waitUntilDone()
        XCTAssertEqual(warns.status?.fragile, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("prep-result.json").path), "read, then gone")
    }

    /// What the job shows comes from print prep's report, not its log (#218): rewording a line
    /// in prep.log changes nothing.
    func testWarningsComeFromTheReportNotTheLog() throws {
        let fx = try Fixture(); _ = try fx.mini("elf")
        let says = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "echo 'mini_prep: WARNING footprint'; echo '\(Prep.partWarning)A part.'")))
        try says.resize(name: "elf", sizes: sizes); says.waitUntilDone()
        XCTAssertEqual(says.status?.notes, [])
        XCTAssertEqual(says.status?.fragile, false)
    }

    /// A part print prep left out, or an object that needs a base, is said in its own words,
    /// beside the generic fragile line that the footprint warning still gets.
    func testAPartLeftOutIsSaidInItsOwnWords() throws {
        let fx = try Fixture(); _ = try fx.mini("elf")
        let part = "A part came out separate from the figure (about 30 mm long) and was left out."
        let stand = "It needs a base to stand."
        let one = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.prep("prep", PrepReport(warnings: [.init(.part, part), .init(.stand, stand)]))))
        try one.resize(name: "elf", sizes: sizes); one.waitUntilDone()
        XCTAssertEqual(one.status?.notes, [part, stand])
        XCTAssertEqual(one.status?.fragile, false)
        let both = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.prep("prep2", PrepReport(warnings: [.init(.footprint, "footprint"), .init(.part, part)]))))
        try both.resize(name: "elf", sizes: sizes); both.waitUntilDone()
        XCTAssertEqual(both.status?.notes, [part])
        XCTAssertEqual(both.status?.fragile, true)
    }

    /// The warnings are kept with the mini (#80), for its page after a relaunch, until a run
    /// replaces them; why a run failed too (#78), until one finishes.
    func testWarningsAndFailuresAreKeptWithTheMini() throws {
        let fx = try Fixture(); let d = try fx.mini("elf")
        let part = "A part came out separate from the figure (about 30 mm long) and was left out."
        let warns = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.prep("prep", PrepReport(warnings: [.init(.footprint, "footprint"), .init(.part, part)]))))
        try warns.resize(name: "elf", sizes: sizes); warns.waitUntilDone()
        XCTAssertEqual(MiniSettings.load(d).notes, [part])
        XCTAssertEqual(MiniSettings.load(d).fragile, true)
        let fails = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.prep("prep2", PrepReport(failure: "the model is flat"), "exit 1")))
        try fails.resize(name: "elf", sizes: sizes); fails.waitUntilDone()
        XCTAssertEqual(MiniSettings.load(d).failed, "the model is flat", "why it failed is kept")
        XCTAssertEqual(MiniSettings.load(d).failedStep, 3)
        XCTAssertEqual(MiniSettings.load(d).notes, [part], "a failed run leaves the print file, and its warnings, as they were")
        let quiet = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        try quiet.resize(name: "elf", sizes: sizes); quiet.waitUntilDone()
        let s = MiniSettings.load(d)
        XCTAssertNil(s.notes); XCTAssertNil(s.fragile); XCTAssertNil(s.failed, "a finished run clears them")
    }

    /// Why the 3D step failed reaches the person as `mimic _engine` said it, in its report (#305):
    /// on the job, and kept with the mini. Killed outright (signal 9, which is how macOS ends a
    /// program when the Mac runs out of memory) it says so; with no reason at all, which step
    /// stopped, keeping its own capitals.
    func testTheReasonThe3DStepFailedIsSaid() throws {
        let fx = try Fixture()
        let picture = try fx.picture()
        try fx.modelFiles()
        func make(_ name: String, _ mimic: String) throws -> (JobStatus?, MiniSettings) {
            let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: mimic), trash: { _ in })
            try jobs.make(name: name, picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
            jobs.waitUntilDone()
            return (jobs.status, MiniSettings.load(fx.install.runs.appendingPathComponent(name)))
        }
        let why = "Couldn't find the character in the picture. Try one with a plain background."
        let (said, saved) = try make("said", try fx.prep("says-why", PrepReport(failure: why), "echo 'Traceback: boom' >&2; exit 1"))
        XCTAssertEqual(said?.problem, why)
        XCTAssertEqual(saved.failed, why)
        XCTAssertEqual(saved.failedStep, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.install.runs.appendingPathComponent("said/prep-result.json").path))

        let memory = "It looks like your Mac ran out of memory while building the 3D shape. Quit other apps, then try again."
        let (killed, killedSaved) = try make("killed", try fx.script("killed", "if [ \"$1\" = _engine ]; then kill -9 $$; fi"))
        XCTAssertEqual(killed?.exit, -9)
        XCTAssertEqual(killed?.problem, memory)
        XCTAssertEqual(killedSaved.failed, memory)

        let (quiet, quietSaved) = try make("quiet", try fx.script("quiet", "if [ \"$1\" = _engine ]; then echo 'exit code 3' >&2; exit 1; fi"))
        XCTAssertEqual(quiet?.problem, "It stopped while building the 3D shape.")
        XCTAssertEqual(quietSaved.failed, "It stopped while building the 3D shape.")
    }

    /// A step that fails inside Mimic says so in plain words (#324), not as Swift's raw error
    /// text: here its picture went before it could be copied, a Cocoa error. The raw text goes
    /// in the job's log, for a bug report.
    func testAFailureInsideMimicIsSaidPlainly() throws {
        let fx = try Fixture()
        try fx.modelFiles()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(), trash: { _ in })
        try jobs.setPaused(true)
        try jobs.make(name: "gone", picture: .image(try fx.picture()), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        let d = fx.install.runs.appendingPathComponent("gone")
        try FileManager.default.removeItem(at: d.appendingPathComponent("upload.img"))
        try jobs.setPaused(false)
        jobs.waitUntilDone()
        let said = "It stopped while getting the picture ready."
        XCTAssertEqual(jobs.status?.problem, said)
        XCTAssertEqual(MiniSettings.load(d).failed, said)
        let log = (try? String(contentsOf: d.appendingPathComponent("generate.job.log"), encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("NSCocoaErrorDomain"), "the raw error isn't in the log: \(log)")
    }

    /// Mimic's own errors are already in plain words; anything else has none, for the caller's own.
    func testOnlyMimicsOwnErrorsAreInPlainWords() {
        XCTAssertEqual(plainWords(RequestError.noPicture), RequestError.noPicture.description)
        XCTAssertEqual(plainWords(HelperError.busy), HelperError.busy.description)
        XCTAssertEqual(plainWords(Refusal("No.")), "No.")
        XCTAssertNil(plainWords(CocoaError(.fileNoSuchFile)))
        XCTAssertNil(plainWords(URLError(.badServerResponse)))
    }

    /// Stop during the 3D step: the job and its child end, it reads as stopped, and the
    /// half-made mini goes to the Trash.
    func testStopEndsTheJobAndTrashesAHalfMadeMini() throws {
        let fx = try Fixture()
        let childFile = fx.root.appendingPathComponent("child.pid").path
        let engine = try fx.script("fake-engine", "sleep 60 & echo $! > \(childFile); wait")
        let picture = try fx.picture()
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: engine), trash: { spy($0) })
        try fx.modelFiles()
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        var child: pid_t = 0
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: childFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { child = p; break }
            usleep(50_000)
        }
        XCTAssertEqual(jobs.status?.step, .shape)
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.canceled, true)
        XCTAssertNotEqual(jobs.status?.exit, 0)
        usleep(200_000)
        XCTAssertNotEqual(kill(child, 0), 0, "Stop left the 3D engine's child running")
        XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["mini"])
        XCTAssertEqual(jobs.status?.stopSays, "Nothing was kept. It's in the Trash if you want the pieces.")
        XCTAssertFalse(jobs.cancel(), "Stop acted on a job that had already ended (#322)")
    }

    /// Stopping Try Again of a mini that failed in the 3D step (#178): it goes back to how it
    /// failed, with its picture and settings, instead of to the Trash as a new mini does (above).
    /// The shape it was half way through goes, so the next Try Again builds it again. Taken out
    /// of the queue while it waits, it stays too.
    func testStoppingTryAgainKeepsTheFailedMini() throws {
        let fx = try Fixture()
        let started = fx.root.appendingPathComponent("started").path
        let failing = try fx.script("failing-mimic", "if [ \"$1\" = _engine ]; then exit 1; fi")
        let picture = try fx.picture()
        try fx.modelFiles()
        let first = JobRunner(install: fx.install, tools: fx.tools(mimic: failing), trash: { _ in })
        try first.make(name: "mini", picture: .image(picture), restyle: false, seed: 7, sizes: sizes, model: EngineDownload.standard)
        first.waitUntilDone()
        let d = fx.install.runs.appendingPathComponent("mini")
        let failed = MiniSettings.load(d)
        XCTAssertNotNil(failed.failed)
        XCTAssertEqual(failed.failedStep, JobStep.shape.rawValue)

        // Step 2 writes part of its 3D shape and waits to be stopped.
        let fake = try fx.script("fake-mimic", """
            if [ "$1" = _engine ]; then echo half > "$3"; touch \(started); sleep 60 & wait; fi
            """)
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: fake), trash: { spy($0) })
        try jobs.retry(name: "mini")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }
        XCTAssertEqual(jobs.status?.step, .shape)
        XCTAssertEqual(jobs.status?.stopAsks, "It's kept, so you can try again later.", "Stop's question says it's kept")
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertEqual(jobs.status?.canceled, true)
        XCTAssertEqual(spy.trashed, [], "stopping Try Again threw the mini away")
        XCTAssertEqual(jobs.status?.stopSays, "It was kept, so you can try again later.", "said as kept, not as in the Trash")
        let after = MiniSettings.load(d)
        XCTAssertEqual(after.failed, failed.failed, "it isn't failed any more")
        XCTAssertEqual(after.failedStep, failed.failedStep)
        XCTAssertEqual(after.seed, 7); XCTAssertEqual(after.requested, sizes); XCTAssertEqual(after.model, failed.model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent("upload.img").path), "its picture went")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("model.glb").path), "a half-built shape was kept")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: after, tools: fx.tools()).map(\.number), [.shape, .print])
        XCTAssertEqual(jobs.queue.entries(), [], "a stopped Try Again starts again by itself")

        try jobs.setPaused(true)
        try jobs.retry(name: "mini")
        let waiting = try XCTUnwrap(jobs.queue.entries().first)
        XCTAssertEqual(waiting.takeOutSays(importing: false), "It stays, so you can try again later.")
        XCTAssertTrue(try jobs.remove("mini"))
        XCTAssertEqual(spy.trashed, [], "taking Try Again out of the queue threw the mini away")
        XCTAssertNotNil(Gallery.folder(fx.install.runs, "mini"))
    }

    /// Stop ends the job only once everything it started has ended too (#174): a program slow
    /// to die on SIGTERM can't hold memory into the next job, or outlive Mimic quitting with
    /// no record left to stop it by.
    func testStopWaitsForEverythingTheJobStarted() throws {
        let fx = try Fixture()
        let childFile = fx.root.appendingPathComponent("child.pid").path
        // The engine ends at once; what it started takes 2 s more.
        let engine = try fx.script("fake-engine", "(trap '' TERM; sleep 2) & echo $! > \(childFile); wait")
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: engine), trash: { _ in })
        try fx.modelFiles()
        try jobs.make(name: "mini", picture: .image(try fx.picture()), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        var child: pid_t = 0
        for _ in 0..<100 {
            if let s = try? String(contentsOfFile: childFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { child = p; break }
            usleep(50_000)
        }
        XCTAssertGreaterThan(child, 0)
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertNotEqual(kill(child, 0), 0, "the job ended while what it started still ran")
        XCTAssertFalse(Leftover.recorded(queue: fx.install.queue))
    }

    /// `mimic make` stops its job when its Terminal window is closed or it's killed, not only on
    /// Ctrl-C (#174): the job's programs, in a session of their own, don't hear it themselves.
    func testClosingTheTerminalOrKillStopsTheJob() throws {
        let saved = [SIGINT, SIGHUP, SIGTERM].map { sig -> (Int32, sigaction) in
            var old = sigaction()
            sigaction(sig, nil, &old)
            return (sig, old)
        }
        defer { for (sig, old) in saved { var o = old; sigaction(sig, &o, nil) } }
        for sig in [SIGHUP, SIGTERM] {
            let fx = try Fixture()
            let started = fx.root.appendingPathComponent("started").path, termed = fx.root.appendingPathComponent("termed").path
            // Ends as soon as it hears SIGTERM, as the 3D engine should.
            let engine = try fx.script("fake-engine", "trap 'touch \(termed); exit 143' TERM; touch \(started); sleep 60 & wait")
            let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: engine), trash: { _ in })
            // Listening before the job starts, as `mimic make` does: its programs still hear Stop.
            let signals = jobs.stopOnSignals()
            try fx.modelFiles()
            try jobs.make(name: "mini", picture: .image(try fx.picture()), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }
            let asked = Date()
            // Until it's heard: the listener may not be up yet.
            for _ in 0..<100 where jobs.status?.canceled != true { kill(getpid(), sig); usleep(50_000) }
            jobs.waitUntilDone()
            signals.forEach { $0.cancel() }
            XCTAssertEqual(jobs.status?.canceled, true, "signal \(sig) didn't stop the job")
            XCTAssertTrue(FileManager.default.fileExists(atPath: termed), "the job's program never heard SIGTERM")
            XCTAssertLessThan(Date().timeIntervalSince(asked), 4, "it took the SIGKILL after the grace to stop it")
        }
    }

    /// Quitting during a make (#82): the mini goes back to the front of the queue, not to the
    /// Trash, and the next run starts at the step it was on. The step's half-written file goes,
    /// so it isn't taken for a finished one.
    func testQuittingPutsTheMiniBackAtTheFrontAndKeepsTheWork() throws {
        let fx = try Fixture(); _ = try fx.mini("b")
        let started = fx.root.appendingPathComponent("started").path
        // Step 2 writes part of its 3D shape and waits to be stopped.
        let fake = try fx.script("fake-mimic", """
            if [ "$1" = _engine ]; then echo half > "$3"; touch \(started); sleep 60 & wait; fi
            """)
        let picture = try fx.picture()
        let spy = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: fake), trash: { spy($0) })
        try fx.modelFiles()
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        XCTAssertEqual(try jobs.resize(name: "b", sizes: sizes), 1)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }
        XCTAssertEqual(jobs.status?.step, .shape)
        jobs.keepGoing = { _ in false }
        XCTAssertTrue(jobs.cancel(keepingWork: true))
        jobs.waitUntilDone()
        let d = fx.install.runs.appendingPathComponent("mini")
        XCTAssertEqual(spy.trashed, [], "quitting threw the mini away")
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["mini", "b"], "it goes back first")
        XCTAssertEqual(jobs.queue.entries().first?.job, .generate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent("model.glb").path), "a half-built shape was kept")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: MiniSettings.load(d), tools: fx.tools()).map(\.number), [.shape, .print],
                       "the picture is kept")
        XCTAssertNil(MiniSettings.load(d).failed, "quitting isn't a failure")
    }

    /// Quitting in the last step keeps the 3D shape, so it isn't built again (minutes).
    func testQuittingInTheLastStepKeepsTheShape() throws {
        let fx = try Fixture()
        let started = fx.root.appendingPathComponent("started").path
        let fake = try fx.script("fake-mimic", """
            if [ "$1" = _engine ]; then echo shape > "$3"; else touch \(started); sleep 60 & wait; fi
            """)
        let picture = try fx.picture()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: fake), trash: { _ in })
        try fx.modelFiles()
        try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }
        XCTAssertEqual(jobs.status?.step, .print)
        jobs.keepGoing = { _ in false }
        XCTAssertTrue(jobs.cancel(keepingWork: true))
        jobs.waitUntilDone()
        let d = fx.install.runs.appendingPathComponent("mini")
        XCTAssertEqual(jobs.queue.entries().map(\.name), ["mini"])
        XCTAssertEqual(try String(contentsOf: d.appendingPathComponent("model.glb"), encoding: .utf8), "shape\n")
        XCTAssertEqual(try Pipeline.plan(.generate, folder: d, settings: MiniSettings.load(d), tools: fx.tools()).map(\.number), [.print])
        // The next launch carries on with it, and it finishes.
        let next = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"))
        next.pump(); next.waitUntilDone()
        XCTAssertEqual(next.status?.name, "mini")
        XCTAssertEqual(next.status?.succeeded, true)
        XCTAssertEqual(next.queue.entries(), [])
    }

    /// Stop then quit while the job is still ending (#171): the stopped mini goes to the Trash
    /// and doesn't start again next launch. Quit then Stop keeps it, as quitting promised.
    func testTheFirstStopOrQuitDecidesWhatIsKept() throws {
        for (first, then) in [(false, true), (true, false)] {
            let fx = try Fixture()
            let started = fx.root.appendingPathComponent("started").path
            // Takes a second to end once stopped: the window the second ask lands in.
            let fake = try fx.script("fake-mimic", """
                trap 'sleep 1; exit 143' TERM; touch \(started); sleep 60 & wait
                """)
            let picture = try fx.picture()
            let spy = TrashSpy()
            let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: fake), trash: { spy($0) })
            try fx.modelFiles()
            try jobs.make(name: "mini", picture: .image(picture), restyle: false, seed: 1, sizes: sizes, model: EngineDownload.standard)
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: started) { usleep(50_000) }
            jobs.keepGoing = { _ in false }
            XCTAssertTrue(jobs.cancel(keepingWork: first))
            XCTAssertEqual(jobs.status?.running, true, "it ended before the second ask")
            XCTAssertTrue(jobs.cancel(keepingWork: then))
            jobs.waitUntilDone()
            if first {
                XCTAssertEqual(spy.trashed, [], "a Stop after quitting threw the mini away")
                XCTAssertEqual(jobs.queue.entries().map(\.name), ["mini"])
            } else {
                XCTAssertEqual(spy.trashed.map(\.lastPathComponent), ["mini"], "quitting after Stop kept the stopped mini")
                XCTAssertEqual(jobs.queue.entries(), [], "the stopped mini would start again next launch")
            }
        }
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
        let fd = open(fx.install.queue.appendingPathComponent("job.lock").path, O_CREAT | O_RDWR, 0o644)
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
        Leftover.record(pid: orphan.pid, queue: fx.install.queue)
        XCTAssertTrue(Leftover.stop(queue: fx.install.queue))
        XCTAssertEqual(orphan.wait(), -15)

        let unrelated = try GroupProcess(executable: "/bin/sleep", arguments: ["60"], environment: [:])
        try "\(unrelated.pid) 12345".write(to: Leftover.file(queue: fx.install.queue), atomically: true, encoding: .utf8)
        XCTAssertFalse(Leftover.stop(queue: fx.install.queue), "a pid whose start time doesn't match must not be stopped")
        XCTAssertEqual(kill(unrelated.pid, 0), 0)
        unrelated.terminateGroup(); unrelated.wait()
    }
}
