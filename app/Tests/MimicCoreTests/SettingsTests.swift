import XCTest
@testable import MimicCore

/// Ported from tests/test_settings.py (the storage half; the job half is in JobTests).
final class SettingsTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

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

    /// A file that's there but doesn't read (a hand edit, a newer Mimic's value) is never written
    /// over, which would lose everything it says (#179). An empty one, or none, is written.
    func testAFileThatDoesntReadIsLeftAsItIs() throws {
        let file = folder.appendingPathComponent("settings.json")
        for text in ["{ not json", #"{"source": "video", "desc": "a dwarf", "seed": 42}"#] {
            try text.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try MiniSettings.update(folder) { $0.made = Sizes(height: "32") }) {
                XCTAssertEqual($0 as? RequestError, .unreadableSettings(folder.lastPathComponent))
            }
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
        }
        try Data().write(to: file)
        try MiniSettings.update(folder) { $0.seed = 7 }
        XCTAssertEqual(MiniSettings.load(folder).seed, 7)
    }

    /// What a newer Mimic wrote that this one doesn't know is kept when it writes the file back
    /// (#326): two Macs may share a minis folder. What it knows and clears is still cleared.
    func testWhatANewerMimicWroteIsKept() throws {
        let file = folder.appendingPathComponent("settings.json")
        try #"{"seed": 42, "failed": "It stopped.", "pose": {"arms": "raised"}, "tags": ["elf", 3]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        try MiniSettings.update(folder) { $0.seed = 7; $0.failed = nil }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! NSDictionary
        XCTAssertEqual(json, ["seed": 7, "pose": ["arms": "raised"], "tags": ["elf", 3]])
    }

    /// Changes to one mini's settings take turns, so none is lost to another made at the same
    /// time (a rename while it's resized, #179).
    func testUpdatesTakeTurns() throws {
        let folder = folder!
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            try? MiniSettings.update(folder) { $0.seed = ($0.seed ?? 0) + 1 }
        }
        XCTAssertEqual(MiniSettings.load(folder).seed, 40)
    }

    /// The turn is the folder's, so a mini renamed while its settings are being changed waits
    /// for that change under its new name.
    func testTheTurnFollowsARename() throws {
        let fd = open(folder.path, O_RDONLY)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let renamed = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: folder, to: renamed)
        folder = renamed
        let done = Flag(false)
        Thread.detachNewThread { try? MiniSettings.update(renamed) { $0.seed = 1 }; done.value = true }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(done.value, "changed while another change held the folder")
        flock(fd, LOCK_UN); close(fd)
        let deadline = Date().addingTimeInterval(5)
        while !done.value, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(MiniSettings.load(renamed).seed, 1)
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

    /// A number too big to be a whole Int, from a hand edit or a script, reads as text and the
    /// gallery shows the default size for it, rather than Mimic crashing on every reload (#307).
    func testAHugeNumberReadsWithoutCrashing() throws {
        try #"{"made": {"height": 1e20, "base": 25}, "requested": {"height": -1e20}}"#
            .write(to: folder.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let s = MiniSettings.load(folder)
        XCTAssertEqual(s.made?.height, "1e+20")
        XCTAssertEqual(s.made?.base, "25")
        XCTAssertThrowsError(try s.requested?.flags()) { XCTAssertEqual($0 as? RequestError, .badNumber("height")) }
        XCTAssertEqual(PrintTips.shortLine(s.made!), "32 mm · 0.4 mm nozzle")
        XCTAssertEqual(PrintTips.made(s.made!).first?.value, "32 mm")
        for text in ["1e20", "-1e20", "inf", "nan"] {
            XCTAssertEqual(PrintTips.shortLine(Sizes(height: text)), "32 mm · 0.4 mm nozzle", text)
        }
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

    /// mimic resize keeps what it isn't told, as the app's Resize does: a mini made for a 0.2 mm
    /// nozzle was resized for 0.4.
    func testAResizeKeepsWhatTheMiniWasMadeWith() {
        let made = Sizes(height: "32", base: "25", nozzle: "0.2", shape: .hex, style: .stone, magnet: .mm5x2)
        let kept = Sizes(height: "35").resizing(made, shapeGiven: false, styleGiven: false, magnetGiven: false)
        XCTAssertEqual(kept, Sizes(height: "35", nozzle: "0.2", shape: .hex, style: .stone, magnet: .mm5x2))
        let given = Sizes(height: "35", nozzle: "0.6", shape: .square, style: .plain)
            .resizing(made, shapeGiven: true, styleGiven: true, magnetGiven: true)
        XCTAssertEqual(given, Sizes(height: "35", nozzle: "0.6", shape: .square, style: .plain), "what's given wins, even plain and no magnet")
        XCTAssertEqual(Sizes(height: "35").resizing(nil, shapeGiven: false, styleGiven: false, magnetGiven: false), Sizes(height: "35"))
    }
}
