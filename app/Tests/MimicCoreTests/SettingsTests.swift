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

    /// Only an object says what it is; a character's file stays exactly as before.
    func testKindRoundTripsAndAbsentIsACharacter() throws {
        try MiniSettings.update(folder) { $0.source = .desc; $0.desc = "a teapot"; $0.kind = .object }
        XCTAssertEqual(MiniSettings.load(folder).kind, .object)
        XCTAssertTrue(MiniSettings.load(folder).isObject)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertEqual(json["kind"] as? String, "object")
        try MiniSettings.update(folder) { $0.kind = nil }
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertNil(json["kind"], "a character writes no kind")
        XCTAssertFalse(MiniSettings.load(folder).isObject)
        try #"{"kind": "character"}"#.write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(MiniSettings.load(folder).isObject)
    }

    /// A square or hex base is written; round, and any shape with no base, isn't, so a mini
    /// made before shapes and one made round now read the same.
    func testABaseShapeIsWrittenOnlyWhenItIsntRound() throws {
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "32", nozzle: "0.4", shape: .hex) }
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertEqual(json["requested"] as? [String: String], ["height": "32", "nozzle": "0.4", "shape": "hex"])
        XCTAssertEqual(MiniSettings.load(folder).requested?.shape, .hex)
        XCTAssertEqual(try Sizes(shape: .hex).flags(), ["--base-shape", "hex"])
        XCTAssertEqual(try Sizes(style: .stone).flags(), ["--base-style", "stone"])
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "32", shape: .square, style: .cobble) }
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: [String: String]])["requested"],
                       ["height": "32", "shape": "square", "style": "cobble"])
        XCTAssertEqual(MiniSettings.load(folder).requested?.style, .cobble)
        for sizes in [Sizes(height: "32", shape: .round), Sizes(height: "32", noBase: true, shape: .square, style: .wood)] {
            try MiniSettings.update(folder) { $0.requested = sizes }
            json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: Any]
            XCTAssertNil((json["requested"] as? [String: String])?["shape"])
            XCTAssertNil((json["requested"] as? [String: String])?["style"])
            XCTAssertFalse(try sizes.flags().contains("--base-shape"))
            XCTAssertFalse(try sizes.flags().contains("--base-style"))
            XCTAssertEqual(MiniSettings.load(folder).requested, sizes)
        }
        try #"{"requested": {"height": "32", "shape": "star"}}"#.write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MiniSettings.load(folder).requested?.shape, .round, "a shape it doesn't know reads as round")
    }

    /// A magnet hole is written only when chosen, and never with no base: so minis made before
    /// magnets, and those without one, read the same.
    func testAMagnetHoleIsWrittenOnlyWhenChosen() throws {
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "32", shape: .hex, magnet: .mm6x2) }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: [String: String]]
        XCTAssertEqual(json["requested"], ["height": "32", "shape": "hex", "magnet": "6x2"])
        XCTAssertEqual(MiniSettings.load(folder).requested?.magnet, .mm6x2)
        XCTAssertEqual(try Sizes(magnet: .mm8x3).flags(), ["--magnet", "8x3"])
        let bare = Sizes(height: "32", noBase: true, magnet: .mm5x2)
        XCTAssertNil(bare.magnet, "no base, no hole")
        XCTAssertFalse(try bare.flags().contains("--magnet"))
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "32") }
        let plain = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: [String: String]]
        XCTAssertNil(plain["requested"]?["magnet"])
        try #"{"requested": {"height": "32", "magnet": "9x9"}, "made": {"height": "32", "magnet": "5x2", "nobase": "1"}}"#
            .write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(MiniSettings.load(folder).requested?.magnet, "a magnet it doesn't know reads as none")
        XCTAssertNil(MiniSettings.load(folder).made?.magnet, "and so does one with no base")
    }

    /// And the web version must be able to read what the app writes (strings, nobase "1").
    func testWritesTheWebFormat() throws {
        try MiniSettings.update(folder) { $0.requested = Sizes(height: "32", nozzle: "0.4", noBase: true) }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as! [String: Any]
        let req = json["requested"] as! [String: String]
        XCTAssertEqual(req, ["height": "32", "nozzle": "0.4", "nobase": "1"])
    }
}
