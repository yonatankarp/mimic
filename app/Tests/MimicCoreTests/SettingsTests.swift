import XCTest
@testable import MimicCore

/// Ported from tests/test_settings.py (the storage half; the job half is in JobTests).
final class SettingsTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func testWritesMerge() throws {
        try MiniSettings.update(folder) { $0.source = .desc; $0.desc = "a dwarf" }
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "100", base: "40", nozzle: "0.4") }
        let s = MiniSettings.load(folder)
        XCTAssertEqual(s.source, .desc)
        XCTAssertEqual(s.desc, "a dwarf")
        XCTAssertEqual(s.requested, Sizes(height: "100", base: "40", nozzle: "0.4"))
    }

    func testUnreadableSettingsReadAsEmpty() throws {
        try "{ not json".write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MiniSettings.load(folder), MiniSettings())
    }

    /// The web version wrote this exact file; the app must read it the same way.
    func testReadsWhatTheWebVersionWrote() throws {
        let web = """
        {"source": "image", "desc": "", "restyle": true, "seed": 42,
         "requested": {"height": "32", "base": "25", "nozzle": "0.2", "nobase": "1"},
         "made": {"height": "32", "base": "25", "nozzle": "0.2"}}
        """
        try web.write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let s = MiniSettings.load(folder)
        XCTAssertEqual(s.source, .image)
        XCTAssertEqual(s.restyle, true)
        XCTAssertEqual(s.seed, 42)
        XCTAssertEqual(s.requested, Sizes(height: "32", base: "25", nozzle: "0.2", noBase: true))
        XCTAssertEqual(s.made, Sizes(height: "32", base: "25", nozzle: "0.2"))
    }

    /// And the web version must be able to read what the app writes (strings, nobase "1").
    func testWritesTheWebFormat() throws {
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "32", nozzle: "0.4", noBase: true) }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: Any]
        let req = json["requested"] as! [String: String]
        XCTAssertEqual(req, ["height": "32", "nozzle": "0.4", "nobase": "1"])
    }
}
