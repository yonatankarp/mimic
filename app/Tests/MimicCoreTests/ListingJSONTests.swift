import XCTest
@testable import MimicCore

/// `--json` (#130): scripts rely on these field names, so renaming one has to fail here. Adding
/// one means adding it here and to docs/cli.md's description.
final class ListingJSONTests: XCTestCase {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ListingJSON.encoder.encode(value)) as? [String: Any])
    }

    private func keys(_ o: [String: Any]?) -> [String] { (o ?? [:]).keys.sorted() }

    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    /// A mini with everything recorded, so no field is left out for having no value.
    private func fullMini(_ fx: Fixture) throws -> (Mini, [Mini]) {
        _ = try fx.mini("orc"); let d = try fx.mini("orc-2")
        try MiniSettings.update(d) {
            $0.made = Sizes(height: "32", base: "25", nozzle: "0.4", inflate: "0.3", shape: .hex, style: .stone, magnet: .mm6x2)
            $0.source = .image; $0.desc = "an orc"; $0.descOriginal = "orc"; $0.seed = 7; $0.shapeSeed = 9; $0.model = EngineDownload.standard.id
            $0.restyle = true; $0.cartoon = true; $0.versionOf = "orc"; $0.created = self.day; $0.failed = "It stopped."
            $0.name("Grok 2", folder: "orc-2")
        }
        try FileManager.default.createDirectory(at: fx.install.runs.appendingPathComponent("Warband"), withIntermediateDirectories: true)
        let minis = Gallery.list(fx.install.runs)
        return (try XCTUnwrap(minis.first { $0.name == "orc-2" }), minis)
    }

    func testListFields() throws {
        let fx = try Fixture(); let (mini, _) = try fullMini(fx)
        var row = ListingJSON.MiniRow(mini, waiting: [])
        row.project = "Warband"
        let o = try object(row)
        XCTAssertEqual(keys(o), ["created", "file", "folder", "kind", "name", "project", "shown", "state"])
        XCTAssertEqual(o["created"] as? String, "2026-09-21T14:13:20Z", "dates are ISO 8601")
        XCTAssertEqual(o["shown"] as? String, "Grok 2")
        XCTAssertEqual(o["state"] as? String, "ready")
    }

    func testProjectFields() throws {
        let fx = try Fixture(); let (mini, _) = try fullMini(fx)
        var inside = mini; inside.project = "Warband"
        let o = try object(ListingJSON.Project("Warband", minis: [inside, mini]))
        XCTAssertEqual(keys(o), ["minis", "name"])
        XCTAssertEqual(o["minis"] as? Int, 1)
    }

    func testQueueFields() throws {
        var running = JobStatus(name: "orc", kind: .prep, step: .print, started: day)
        running.stepStarted = day
        let entry = QueueEntry(name: "elf", job: .generate, added: day)
        let q = ListingJSON.Queue(running: running, left: 61.4, held: .paused,
                                  waiting: [(entry, Estimate(steps: [.picture: 30, .shape: 400, .print: 50], learned: false), 541)])
        let o = try object(q)
        XCTAssertEqual(keys(o), ["held", "running", "waiting"])
        XCTAssertEqual(keys(o["running"] as? [String: Any]), ["job", "name", "secondsLeft", "started", "step"])
        let waiting = try XCTUnwrap(o["waiting"] as? [[String: Any]])
        XCTAssertEqual(keys(waiting.first), ["added", "job", "name", "place", "readyIn", "seconds"])
        XCTAssertEqual((o["running"] as? [String: Any])?["job"] as? String, "resize")
        XCTAssertEqual(waiting.first?["job"] as? String, "make")
        XCTAssertEqual(waiting.first?["seconds"] as? Int, 480)
        XCTAssertEqual(o["held"] as? String, "paused")
        XCTAssertEqual(try object(ListingJSON.Queue(running: nil, left: 0, held: .battery, waiting: []))["held"] as? String, "battery")
    }

    func testModelFields() throws {
        let o = try object(ListingJSON.Model(EngineDownload.standard, downloaded: false, selected: true))
        XCTAssertEqual(keys(o), ["about", "bytes", "downloaded", "id", "name", "selected"])
    }

    func testInfoFields() throws {
        let fx = try Fixture(); let (mini, minis) = try fullMini(fx)
        var info = ListingJSON.Info(MiniInfo(mini, in: minis, waiting: []), waiting: [])
        info.measured = .init(height: 34, width: 26, depth: 25, filamentGrams: 4.1, filamentMetres: 1.3)
        info.failed = "It stopped."
        let o = try object(info)
        XCTAssertEqual(keys(o), ["failed", "made", "madeFrom", "measured", "mini", "versions"])
        XCTAssertEqual(keys(o["made"] as? [String: Any]), ["base", "height", "inflate", "magnet", "noBase", "nozzle", "shape", "style"])
        XCTAssertEqual(keys(o["measured"] as? [String: Any]), ["depth", "filamentGrams", "filamentMetres", "height", "width"])
        XCTAssertEqual(keys(o["madeFrom"] as? [String: Any]), ["cartoon", "description", "greySculpt", "model", "seed", "shapeSeed", "source", "typed"])
        XCTAssertEqual(o["versions"] as? [String], ["orc", "orc-2"])
        XCTAssertEqual((o["made"] as? [String: Any])?["shape"] as? String, "hex")
    }

    /// An imported mini wasn't made by a 3D model, so `info --json` names none, as the text doesn't
    /// (#328). It has `requested` sizes, which is what made it read as Pixal3D.
    func testAnImportedMiniNamesNoModel() throws {
        let fx = try Fixture(); let d = try fx.mini("ogre")
        try MiniSettings.update(d) { $0.imported = "ogre.stl"; $0.requested = Sizes(height: "32") }
        let minis = Gallery.list(fx.install.runs); let mini = try XCTUnwrap(minis.first)
        let o = try object(ListingJSON.Info(MiniInfo(mini, in: minis, waiting: []), waiting: []))
        XCTAssertNil((o["madeFrom"] as? [String: Any])?["model"])
    }

    /// `measured` from a real print file, 20.6 wide, 24.2 deep and 32.8 tall: whole millimetres
    /// (rounded, not cut off) and the filament its 16,351 mm³ takes, to 0.1 g and 0.01 m.
    func testMeasuredIsRoundedFromThePrintFile() throws {
        let fx = try Fixture(); let d = try fx.mini("ogre")
        try STL.write(PrepTests.box(half: [10.3, 12.1, 16.4]), to: d.appendingPathComponent("ogre.stl"))
        let minis = Gallery.list(fx.install.runs); let mini = try XCTUnwrap(minis.first)
        let info = ListingJSON.Info(MiniInfo(mini, in: minis, waiting: []), waiting: [])
        XCTAssertEqual(info.measured, .init(height: 33, width: 21, depth: 24, filamentGrams: 20.3, filamentMetres: 6.8))
    }

    /// JSONEncoder refuses inf and nan, so one size edited by hand to either broke `info --json`
    /// (#379). It's left out, as a size with no value is.
    func testASizeThatIsntANumberIsLeftOut() throws {
        let fx = try Fixture(); let (mini, minis) = try fullMini(fx)
        var info = ListingJSON.Info(MiniInfo(mini, in: minis, waiting: []), waiting: [])
        info.made = ListingJSON.SizesRow(Sizes(height: "inf", base: "nan", nozzle: "-inf", inflate: "0.3"))
        let made = try XCTUnwrap(object(info)["made"] as? [String: Any])
        XCTAssertEqual(keys(made), ["inflate", "noBase", "shape", "style"])
        XCTAssertEqual(made["inflate"] as? Double, 0.3)
    }

    // MARK: From outside (#358)

    // The command itself is in the app's target, out of the tests' reach, so these run the built
    // `mimic` as a script would: what it prints, every field named in docs/cli.md, and its exit codes.

    /// Every field: orc-2 in a project, measured from a real print file and with a fix asked for;
    /// orc unfinished, so it says why.
    func testListProjectsModelsAndInfoFromOutside() throws {
        let fx = try Fixture(); _ = try fullMini(fx)
        let runs = fx.install.runs, made = runs.appendingPathComponent("Warband/orc-2"), orc = runs.appendingPathComponent("orc")
        try FileManager.default.moveItem(at: runs.appendingPathComponent("orc-2"), to: made)
        try STL.write(PrepTests.box(half: [10, 10, 15]), to: made.appendingPathComponent("orc-2.stl"))
        try MiniSettings.update(made) { $0.fixes = ["a bigger axe"] }
        try FileManager.default.removeItem(at: orc.appendingPathComponent("orc.stl"))
        try MiniSettings.update(orc) { $0.failed = "It stopped." }

        let list = try XCTUnwrap(json(fx, "list") as? [[String: Any]])
        let rows = Dictionary(list.map { ($0["name"] as? String ?? "", $0) }) { a, _ in a }
        XCTAssertEqual(keys(rows["orc-2"]), ["created", "file", "folder", "kind", "name", "project", "shown", "state"])
        XCTAssertEqual(keys(rows["orc"]), ["created", "folder", "kind", "name", "shown", "state"])
        XCTAssertEqual(try XCTUnwrap(json(fx, "projects") as? [[String: Any]]).map(keys), [["minis", "name"]])
        let models = try XCTUnwrap(json(fx, "models") as? [[String: Any]])
        XCTAssertEqual(models.count, EngineDownload.catalogue.count)
        XCTAssertEqual(Set(models.map(keys)), [["about", "bytes", "downloaded", "id", "name", "selected"]])

        let info = try XCTUnwrap(json(fx, "info", "orc-2") as? [String: Any])
        XCTAssertEqual(keys(info), ["made", "madeFrom", "measured", "mini", "versions"])
        XCTAssertEqual(keys(info["mini"] as? [String: Any]), keys(rows["orc-2"]))
        XCTAssertEqual(keys(info["made"] as? [String: Any]), ["base", "height", "inflate", "magnet", "noBase", "nozzle", "shape", "style"])
        XCTAssertEqual(keys(info["measured"] as? [String: Any]), ["depth", "filamentGrams", "filamentMetres", "height", "width"])
        XCTAssertEqual(keys(info["madeFrom"] as? [String: Any]),
                       ["cartoon", "description", "fixes", "greySculpt", "model", "seed", "shapeSeed", "source", "typed"])
        XCTAssertEqual(try XCTUnwrap(json(fx, "info", "orc") as? [String: Any])["failed"] as? String, "It stopped.")
    }

    /// A job being made, another waiting, and the queue paused.
    func testQueueFromOutside() throws {
        let fx = try Fixture(); _ = try fx.mini("a"); _ = try fx.mini("b")
        let started = fx.root.appendingPathComponent("started").path
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: try fx.script("prep", "touch \(started); sleep 30")))
        addTeardownBlock { jobs.cancel(); jobs.waitUntilDone() }
        _ = try jobs.resize(name: "a", sizes: Sizes(height: "32"))
        _ = try jobs.resize(name: "b", sizes: Sizes(height: "32"))
        try jobs.setPaused(true, start: false)
        XCTAssertTrue(eventually { FileManager.default.fileExists(atPath: started) }, "the job never started")

        let q = try XCTUnwrap(json(fx, "queue") as? [String: Any])
        XCTAssertEqual(keys(q), ["held", "running", "waiting"])
        XCTAssertEqual(keys(q["running"] as? [String: Any]), ["job", "name", "secondsLeft", "started", "step"])
        XCTAssertEqual((q["waiting"] as? [[String: Any]])?.map(keys), [["added", "job", "name", "place", "readyIn", "seconds"]])
        XCTAssertEqual(q["held"] as? String, "paused")
    }

    /// What a script sees when it goes wrong (#404): 1 when it didn't work, 64 when typed wrong.
    /// (130, stopped, needs a make in Terminal stopped with Ctrl-C.)
    func testExitCodesFromOutside() throws {
        let fx = try Fixture()
        XCTAssertEqual(try mimic(fx, ["info", "nobody", "--json"]).code, ExitCode.failed)
        XCTAssertEqual(try mimic(fx, ["info", "--json"]).code, ExitCode.usage)
        XCTAssertEqual(try mimic(fx, ["list", "everything"]).code, ExitCode.usage)
    }

    /// Runs the built `mimic` with `MIMIC_HOME` on the fixture: its exit code and what it printed.
    /// It still reads this Mac's Mimic settings, so nothing here checks a value that depends on
    /// them, such as which model is selected.
    private func mimic(_ fx: Fixture, _ args: [String]) throws -> (code: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Fixture.mimic); p.arguments = args
        p.environment = ["MIMIC_HOME": fx.root.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// `mimic <args> --json`: it works, and prints JSON whose every field docs/cli.md names.
    private func json(_ fx: Fixture, _ args: String...) throws -> Any {
        let command = "mimic \(args.joined(separator: " ")) --json"
        let (code, out) = try mimic(fx, args + ["--json"])
        XCTAssertEqual(code, 0, command)
        let value = try JSONSerialization.jsonObject(with: out)
        let documented = try Self.documented()
        for field in Self.fields(value).sorted() where !documented.contains("`\(field)`") {
            XCTFail("\(command) prints \(field), which docs/cli.md's JSON for scripts doesn't name")
        }
        return value
    }

    /// docs/cli.md's "JSON for scripts", where scripts look up what each field is.
    private static func documented() throws -> Substring {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../docs/cli.md").standardized
        let text = try String(contentsOf: docs, encoding: .utf8)
        let rest = text[try XCTUnwrap(text.range(of: "## JSON for scripts")).upperBound...]
        return rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)]
    }

    /// Every field name in `value`, at any depth.
    private static func fields(_ value: Any) -> Set<String> {
        if let o = value as? [String: Any] { return o.reduce(into: Set(o.keys)) { $0.formUnion(fields($1.value)) } }
        if let a = value as? [Any] { return a.reduce(into: []) { $0.formUnion(fields($1)) } }
        return []
    }

}
