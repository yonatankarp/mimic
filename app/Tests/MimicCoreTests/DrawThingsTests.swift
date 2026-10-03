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
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
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

    /// A server that's on but doesn't answer in time is said to be slow or stuck, not blamed on
    /// the API Server setting (#321).
    func testATimeoutIsNotNotRunning() throws {
        // Listens and never accepts: the Mac takes the connection, and no reply ever comes.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertTrue(withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &len) == 0 }
        })
        let dt = DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))", "DRAWTHINGS_MODEL": "x"], cli: nil)
        dt.requestTimeout = 1
        XCTAssertThrowsError(try dt.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .timedOut) }
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
        XCTAssertEqual(DrawThings.tail("\u{1B}[1mError:\u{1B}[0m model not found\n\n"), "Error: model not found")
    }

    /// Stop ends the CLI, and reads as stopped, not as Draw Things refusing. Even one that
    /// ignores being asked to stop, as the job's other programs are ended (#323).
    func testStopEndsTheCLI() throws {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("fake-dt-\(UUID().uuidString)")
        let ran = cli.path + ".ran"
        try "#!/bin/sh\ntrap '' TERM\ntouch '\(ran)'\nsleep 60\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defer { try? FileManager.default.removeItem(at: cli); try? FileManager.default.removeItem(atPath: ran) }
        let dt = DrawThings(environment: ["DRAWTHINGS_MODEL": "x"], cli: cli.path)
        XCTAssertNil(try dt.openIfNeeded(), "the CLI needs no app")
        // Stopped once the CLI runs, so it's the CLI that's ended.
        DispatchQueue.global().async {
            _ = eventually { FileManager.default.fileExists(atPath: ran) }
            dt.cancel()
        }
        let started = Date()
        XCTAssertThrowsError(try dt.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// The CLI runs like the job's other programs (#323): with Mimic's own environment, not the
    /// shell's tokens; on record while it runs, so a crashed Mimic's is stopped at the next
    /// launch; and its picture is read from where it was told to write it, whatever it prints.
    func testTheCLIRunsLikeMimicsOtherPrograms() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cli = dir.appendingPathComponent("cli"), env = dir.appendingPathComponent("env"), ran = dir.appendingPathComponent("ran")
        let queue = dir.appendingPathComponent("queue")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        env > '\(env.path)'
        for a; do last=$a; done
        printf png > "$last"
        echo "Wrote: /nowhere.png"
        case "$*" in *"a sleepy dwarf"*) touch '\(ran.path)'; sleep 60 ;; esac
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        setenv("MIMIC_TEST_SHELL_TOKEN", "secret", 1)
        defer { unsetenv("MIMIC_TEST_SHELL_TOKEN") }
        let dt = DrawThings(environment: ["DRAWTHINGS_MODEL": "x"], cli: cli.path, queue: queue)

        XCTAssertEqual(try dt.draw(description: "a dwarf", seed: 1), Data("png".utf8))
        let seen = try String(contentsOf: env, encoding: .utf8)
        XCTAssertFalse(seen.contains("MIMIC_TEST_SHELL_TOKEN"), "the shell's environment reached the CLI")
        XCTAssertTrue(seen.contains("PATH=\(Tools.childEnvironment()["PATH"]!)"), "the CLI didn't get Mimic's PATH")

        // As after a crash: the next launch finds the CLI on record and stops it.
        DispatchQueue.global().async {
            _ = eventually { FileManager.default.fileExists(atPath: ran.path) }
            XCTAssertTrue(Leftover.stop(queue: queue), "the running CLI isn't on record")
        }
        let started = Date()
        XCTAssertThrowsError(try dt.draw(description: "a sleepy dwarf", seed: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    /// A fake draw-things-cli that writes "png" as the picture and leaves `ran` behind.
    private func fakeCLI(_ ran: URL) throws -> URL {
        let cli = FileManager.default.temporaryDirectory.appendingPathComponent("fake-dt-\(UUID().uuidString)")
        try "#!/bin/sh\ntouch '\(ran.path)'\nfor a; do last=$a; done\nprintf png > \"$last\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli
    }

    /// A Stop that lands while the model is looked up or the picture resized, before the
    /// request goes out, still stops it (#170): the picture isn't made first.
    func testAStopBeforeTheRequestIsKept() throws {
        let ran = FileManager.default.temporaryDirectory.appendingPathComponent("dt-ran-\(UUID().uuidString)")
        let cli = try fakeCLI(ran)
        defer { try? FileManager.default.removeItem(at: cli); try? FileManager.default.removeItem(at: ran) }
        let dt = DrawThings(environment: ["DRAWTHINGS_MODEL": "x"], cli: cli.path)
        dt.cancel()
        XCTAssertThrowsError(try dt.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .cancelled) }
        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("dt-pic-\(UUID().uuidString).png")
        try Engine.writePNG([UInt8](repeating: 200, count: 8 * 8 * 4), width: 8, height: 8, to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }
        XCTAssertThrowsError(try dt.sculpt(picture: picture, seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "the picture was made after Stop")
        // Through the API too: stopped, not "isn't answering".
        let api = DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:9", "DRAWTHINGS_MODEL": "x"], cli: nil)
        api.cancel()
        XCTAssertThrowsError(try api.draw(description: "a dwarf", seed: 1)) { XCTAssertEqual($0 as? DrawThingsError, .cancelled) }
        // A new job starts afresh.
        dt.reset()
        XCTAssertEqual(try dt.draw(description: "a dwarf", seed: 1), Data("png".utf8))
    }

    /// The runner forgets a stopped job's Stop when the next job starts: its picture is made.
    func testTheNextJobIsNotStoppedByTheLastOnesStop() throws {
        let fx = try Fixture(); try fx.modelFiles()
        let cli = try fakeCLI(fx.root.appendingPathComponent("ran"))
        let dt = DrawThings(environment: ["DRAWTHINGS_MODEL": "x"], home: fx.root,
                            app: DrawThingsApp(enabled: { false }, running: { false }, open: { nil }), cli: cli.path)
        dt.cancel()  // as the last job's Stop left it
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false", drawThings: dt), trash: { _ in })
        try jobs.make(name: "dwarf", picture: .description("a dwarf"), restyle: false, seed: 1, sizes: Sizes(), model: EngineDownload.standard)
        jobs.waitUntilDone()
        XCTAssertEqual(try Data(contentsOf: fx.install.runs.appendingPathComponent("dwarf/source.png")), Data("png".utf8))
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
