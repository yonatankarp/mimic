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

    /// A character keeps today's prompts word for word; anything else gets neutral ones.
    func testPromptsFollowTheKind() {
        XCTAssertEqual(DrawThings.drawPrompt("dwarf", kind: .character), String(format: DrawThings.characterPrompt, "dwarf"))
        XCTAssertEqual(DrawThings.redrawPrompt(kind: .character), DrawThings.sculptPrompt)
        let draw = DrawThings.drawPrompt("round teapot", kind: .object)
        XCTAssertTrue(draw.hasPrefix("round teapot. One single object"), draw)
        for p in [draw, DrawThings.redrawPrompt(kind: .object)] {
            for word in ["miniature", "character", "feet", "fantasy"] { XCTAssertFalse(p.contains(word), "\(word) in: \(p)") }
            for want in ["whole", "centered", "light grey", "grey"] { XCTAssertTrue(p.contains(want), "\(want) missing: \(p)") }
        }
    }

    /// The character sculpt prompt, word for word. A change needs the cartoon check first
    /// (NOTES.md, "Cartoons"): make docs/cartoon-check's two pictures as cartoons, then update this.
    func testTheSculptPromptsAreChecked() {
        XCTAssertEqual(DrawThings.sculptPrompt, "Turn this character into an unpainted grey plastic tabletop miniature sculpt. Keep the same character, pose, face, clothing, weapons and accessories. Clean sculpted forms, bold readable shapes, slightly larger head and hands, feet or hem resting on the ground, no base. Plain light grey studio background, soft even lighting, 3D render.",
                       "The sculpt prompt changed: run the cartoon check in app/NOTES.md (Cartoons), then update this test.")
    }

    /// Nothing listens on port 9, so these never reach the Draw Things running on this Mac.
    private let offline = ["DRAWTHINGS_URL": "http://127.0.0.1:9"]

    /// Asked first, so the private folder (and the macOS prompt reading it brings) is only a fallback.
    func testUsesTheKleinSelectedInDrawThings() throws {
        let klein = try FakeDrawThings(body: #"{"model":"flux_2_klein_4b_q8p.ckpt"}"#)
        defer { klein.stop() }
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:\(klein.port)"], home: nowhere).model(),
                       "flux_2_klein_4b_q8p.ckpt")
        let sdxl = try FakeDrawThings(body: #"{"model":"sdxl_base.ckpt"}"#)
        defer { sdxl.stop() }
        XCTAssertNil(DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:\(sdxl.port)"], home: nowhere).model(),
                     "another model selected and no Klein downloaded")
    }

    func testPicksTheLargestKleinModel() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = home.appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        for f in ["flux_2_klein_4b_q8p.ckpt", "flux_2_klein_9b_q6p.ckpt", "sdxl_base.ckpt"] {
            FileManager.default.createFile(atPath: models.appendingPathComponent(f).path, contents: Data())
        }
        XCTAssertEqual(DrawThings(environment: offline, home: home).model(), "flux_2_klein_9b_q6p.ckpt")
        XCTAssertEqual(DrawThings(environment: ["DRAWTHINGS_MODEL": "mine.ckpt"], home: home).model(), "mine.ckpt")
        XCTAssertNil(DrawThings(environment: offline, home: home.appendingPathComponent("nothing")).model())
    }

    /// Draw Things refuses sizes that aren't multiples of 64 or don't match the picture.
    func testEditSizes() {
        XCTAssertTrue(DrawThings.editSize(width: 1024, height: 1536) == (1024, 1536))
        XCTAssertTrue(DrawThings.editSize(width: 1170, height: 2532) == (704, 1536))
        let (w, h) = DrawThings.editSize(width: 300, height: 200)
        XCTAssertEqual(w, 1536); XCTAssertEqual(h % 64, 0)
    }

    func testUnreachableServerReadsAsNotRunning() {
        let dt = DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:9", "DRAWTHINGS_MODEL": "x"], cli: nil)
        XCTAssertFalse(dt.reachable())
        XCTAssertThrowsError(try dt.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .notRunning) }
    }

    /// The CLI gets the same request, and nothing that sends it to Draw Things' cloud.
    func testCLIArguments() {
        let draw = DrawThings.cliArguments(model: "m.ckpt", prompt: "a dwarf", seed: 7, width: 1024, height: 1024, output: "/o.png")
        XCTAssertEqual(draw.first, "generate")
        XCTAssertFalse(draw.contains { $0.hasPrefix("--cloud") || $0.hasPrefix("--remote") })
        XCTAssertTrue(draw.contains("--no-download-missing"))
        XCTAssertFalse(draw.contains("--image"))
        for (flag, value) in [("--model", "m.ckpt"), ("--prompt", "a dwarf"), ("--seed", "7"), ("--width", "1024"), ("--output", "/o.png")] {
            XCTAssertEqual(draw[draw.firstIndex(of: flag)! + 1], value, flag)
        }
        let edit = DrawThings.cliArguments(model: "m", prompt: "p", seed: 1, width: 704, height: 1536, image: "/in.png", output: "/o.png")
        XCTAssertFalse(edit.contains { $0.hasPrefix("--cloud") || $0.hasPrefix("--remote") })
        XCTAssertEqual(edit[edit.firstIndex(of: "--image")! + 1], "/in.png")
        XCTAssertEqual(edit[edit.firstIndex(of: "--height")! + 1], "1536")
    }

    func testCLIOutput() {
        let out = "\u{1B}[2K\rStep 1/4\n\u{1B}[2K\rStep 4/4\n\u{1B}[2KWrote: /tmp/a b.png\n"
        XCTAssertEqual(DrawThings.wrotePath(out), "/tmp/a b.png")
        XCTAssertNil(DrawThings.wrotePath("Step 1/4\n"))
        XCTAssertEqual(DrawThings.tail("\u{1B}[1mError:\u{1B}[0m model not found\n\n"), "Error: model not found")
    }

    /// Stop ends the CLI, and reads as stopped, not as Draw Things refusing.
    func testStopEndsTheCLI() throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("fake-dt-\(UUID().uuidString)")
        try "#!/bin/sh\nsleep 30\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defer { try? FileManager.default.removeItem(at: cli) }
        let dt = DrawThings(environment: ["DRAWTHINGS_MODEL": "x"], cli: cli.path)
        XCTAssertNil(try dt.openIfNeeded(), "the CLI needs no app")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { dt.cancel() }
        let started = Date()
        XCTAssertThrowsError(try dt.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// The CLI runs at the same lower priority as the job's other programs (#136): the fake one
    /// writes its nice value as the picture.
    func testCLIRunsAtALowerPriority() throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("fake-dt-\(UUID().uuidString)")
        try "#!/bin/sh\nfor a; do last=$a; done\nps -o nice= -p $$ > \"$last\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defer { try? FileManager.default.removeItem(at: cli) }
        let dt = DrawThings(environment: ["DRAWTHINGS_MODEL": "x"], cli: cli.path)
        let nice = String(decoding: try dt.draw(description: "a dwarf", seed: 1), as: UTF8.self)
        // nice adds to what it's started with: whatever runs the tests may already be niced.
        XCTAssertEqual(nice.trimmingCharacters(in: .whitespacesAndNewlines), String(min(20, getpriority(PRIO_PROCESS, 0) + Int32(JobRunner.nice))))
    }
}

/// A real drawing and sculpt through the draw-things-cli setup downloads, about a minute each:
/// setup (the engine and the tool, not the 3D model files) into the folder MIMIC_LIVE_DRAW names,
/// then a picture of a dwarf and its sculpt, left there.
final class LiveDrawTests: XCTestCase {
    func testDrawAndSculptThroughTheCLI() async throws {
        guard let path = ProcessInfo.processInfo.environment["MIMIC_LIVE_DRAW"] else { throw XCTSkip("set MIMIC_LIVE_DRAW=<folder>") }
        let folder = URL(fileURLWithPath: path)
        var setup = EngineSetup(install: .standard(home: folder))
        setup.model.files = []
        try await setup.run { _ in }
        let dt = DrawThings(cli: try XCTUnwrap(DrawThings.findCLI(setup.install), "setup left no draw-things-cli"))
        let wasRunning = DrawThingsApp.mac.running()
        let drawn = folder.appendingPathComponent("live-draw.png"), sculpt = folder.appendingPathComponent("live-sculpt.png")
        try dt.draw(description: "stout dwarf warrior with an axe", seed: 7).write(to: drawn)
        try dt.sculpt(picture: drawn, seed: 7).write(to: sculpt)
        print("LIVE \(drawn.path) \(sculpt.path)")
        if !wasRunning { XCTAssertFalse(DrawThingsApp.mac.running(), "the CLI path opened Draw Things") }
    }
}
