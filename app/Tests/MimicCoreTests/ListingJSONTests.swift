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
}
