import XCTest
@testable import MimicCore

final class DrawThingsTests: XCTestCase {
    /// Every request names its model and sampler; left out, Draw Things uses whatever its own
    /// window has selected, and an edit became plain text-to-image ignoring the picture.
    func testRequestsPinModelAndSampler() {
        let dt = DrawThings(environment: [:])
        let b = dt.body(model: "flux_2_klein_9b_q6p.ckpt", prompt: "p", seed: 7, width: 1024, height: 1536, image: Data([1, 2, 3]))
        XCTAssertEqual(b["model"] as? String, "flux_2_klein_9b_q6p.ckpt")
        XCTAssertEqual(b["sampler"] as? String, "DDIM Trailing")
        XCTAssertEqual(b["steps"] as? Int, 4)
        XCTAssertEqual(b["strength"] as? Double, 1.0, "an edit must redraw at full strength")
        XCTAssertEqual((b["init_images"] as? [String])?.first, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(b["seed"] as? Int, 7)
    }

    func testPicksTheLargestKleinModel() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = home.appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        for f in ["flux_2_klein_4b_q8p.ckpt", "flux_2_klein_9b_q6p.ckpt", "sdxl_base.ckpt"] {
            FileManager.default.createFile(atPath: models.appendingPathComponent(f).path, contents: Data())
        }
        XCTAssertEqual(DrawThings(environment: [:], home: home).model(), "flux_2_klein_9b_q6p.ckpt")
        XCTAssertEqual(DrawThings(environment: ["DRAWTHINGS_MODEL": "mine.ckpt"], home: home).model(), "mine.ckpt")
        XCTAssertNil(DrawThings(environment: [:], home: home.appendingPathComponent("nothing")).model())
    }

    /// Draw Things refuses sizes that aren't multiples of 64 or don't match the picture.
    func testEditSizes() {
        XCTAssertTrue(DrawThings.editSize(width: 1024, height: 1536) == (1024, 1536))
        XCTAssertTrue(DrawThings.editSize(width: 1170, height: 2532) == (704, 1536))
        let (w, h) = DrawThings.editSize(width: 300, height: 200)
        XCTAssertEqual(w, 1536); XCTAssertEqual(h % 64, 0)
    }

    func testUnreachableServerReadsAsNotRunning() {
        let dt = DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:9", "DRAWTHINGS_MODEL": "x"])
        XCTAssertFalse(dt.reachable())
        XCTAssertThrowsError(try dt.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .notRunning) }
    }
}
