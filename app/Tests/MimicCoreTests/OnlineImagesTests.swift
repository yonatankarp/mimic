import ImageIO
import XCTest
@testable import MimicCore

/// The online picture service (#247), against a local stand-in for Black Forest Labs' API: a
/// request is submitted, its polling address asked until Ready, and the picture fetched.
final class OnlineImagesTests: XCTestCase {
    static let picture: Data = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bfl-\(UUID().uuidString).png")
        try! Engine.writePNG([UInt8](repeating: 200, count: 8 * 8 * 4), width: 8, height: 8, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try! Data(contentsOf: url)
    }()

    /// A fake BFL: submits answer with a polling address on this server, which says `status`
    /// (Ready after `pending` asks), and the picture is at /sample.png.
    /// `hiccups`: how many of the first asks fail with `hiccup` (a status, or 0 for a dropped
    /// connection) before it answers.
    static func fake(status: String = "Ready", pending: Int = 0, submit: Int = 200, details: String = "null",
                     hiccups: Int = 0, hiccup: Int = 503) throws -> FakeLLM {
        let asked = Counter()
        nonisolated(unsafe) var port: UInt16 = 0
        let server = try FakeLLM { r in
            let path = r.head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if path.hasPrefix("/v1/flux-2-klein-9b") {
                return (submit, Data(#"{"id":"t1","polling_url":"http://127.0.0.1:\#(port)/v1/get_result?id=t1"}"#.utf8))
            }
            if path.hasPrefix("/v1/get_result") {
                let n = asked.next()
                if n < hiccups { return (hiccup, Data()) }
                let s = n - hiccups < pending ? "Pending" : status
                let result = s == "Ready" ? #"{"sample":"http://127.0.0.1:\#(port)/sample.png"}"# : "null"
                // As api.bfl.ai answers an id it doesn't know: 404, with the status in the body.
                return (s == "Task not found" ? 404 : 200, Data(#"{"id":"t1","status":"\#(s)","result":\#(result),"details":\#(details)}"#.utf8))
            }
            if path == "/sample.png" { return (200, OnlineImagesTests.picture) }
            if path == "/v1/credits" { return (submit, Data(#"{"credits":12.5}"#.utf8)) }
            return (404, Data())
        }
        port = server.port
        return server
    }

    /// A picture's width and height.
    static func size(_ png: Data) -> [Int] {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        return [image.width, image.height]
    }

    private func service(_ server: FakeLLM, key: String? = "k-123") -> BlackForestLabs {
        let s = BlackForestLabs(base: URL(string: "http://127.0.0.1:\(server.port)")!, key: { key })
        s.poll = 0.05
        return s
    }

    private func body(_ r: FakeLLM.Request) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(r.body.utf8))) as? [String: Any] ?? [:]
    }

    /// Text to picture: today's prompt, Klein, a square PNG, the key in its header, and the
    /// picture that comes back.
    func testDrawsFromADescription() throws {
        let server = try Self.fake(pending: 2)
        defer { server.stop() }
        let png = try service(server).draw(description: "stout dwarf", seed: 7, kind: .character)
        XCTAssertEqual(Self.size(png), [1024, 1024], "the 8 × 8 the service sent, at the size Draw Things makes")
        let submit = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(submit.head.hasPrefix("POST /v1/flux-2-klein-9b "), submit.head)
        XCTAssertTrue(submit.head.lowercased().contains("x-key: k-123"))
        let b = body(submit)
        XCTAssertEqual(b["prompt"] as? String, DrawThings.drawPrompt("stout dwarf", kind: .character))
        XCTAssertEqual(b["seed"] as? Int, 7)
        XCTAssertEqual(b["width"] as? Int, 1024)
        XCTAssertEqual(b["output_format"] as? String, "png")
        XCTAssertNil(b["input_image"])
        XCTAssertEqual(server.requests.filter { $0.head.contains("get_result") }.count, 3, "asked until Ready")
        let fetched = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(fetched.head.hasPrefix("GET /sample.png"))
        XCTAssertFalse(fetched.head.lowercased().contains("x-key"), "the picture's address needs no key, so it gets none")
    }

    /// Picture to picture: the sculpt prompt with the change, and the picture itself, at Draw
    /// Things' edit size.
    func testRedrawsAPictureAsASculpt() throws {
        let server = try Self.fake()
        defer { server.stop() }
        let fx = try Fixture()
        let png = try service(server).sculpt(picture: try fx.picture(), seed: 3, kind: .object, change: "a taller lid")
        XCTAssertEqual(Self.size(png), [DrawThings.editSize(width: 8, height: 8).0, DrawThings.editSize(width: 8, height: 8).1])
        let b = body(try XCTUnwrap(server.requests.first))
        XCTAssertEqual(b["prompt"] as? String, DrawThings.redrawPrompt(kind: .object, change: "a taller lid"))
        let (w, h) = DrawThings.editSize(width: 8, height: 8)
        XCTAssertEqual(b["width"] as? Int, w); XCTAssertEqual(b["height"] as? Int, h)
        // A data URL, the form BFL's own FLUX.2 example sends a local picture in.
        let inline = try XCTUnwrap(b["input_image"] as? String)
        XCTAssertTrue(inline.hasPrefix("data:image/png;base64,"), String(inline.prefix(40)))
        let sent = try XCTUnwrap(Data(base64Encoded: String(inline.dropFirst("data:image/png;base64,".count))))
        XCTAssertTrue(sent.starts(with: [0x89, 0x50, 0x4E, 0x47]), "the picture goes as a PNG")
    }

    /// No key: nothing is sent. A key turned down says so, in Settings' Test too.
    func testAMissingOrWrongKey() throws {
        let server = try Self.fake(submit: 403)
        defer { server.stop() }
        XCTAssertThrowsError(try service(server, key: " ").draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .noKey)
        }
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertThrowsError(try service(server).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .badKey)
        }
        XCTAssertThrowsError(try service(server).check()) { XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .badKey) }
        let good = try Self.fake()
        defer { good.stop() }
        // A key not shaped like one: api.bfl.ai answers 422 "Invalid API key format", seen live.
        let malformed = try FakeLLM(status: 422, body: #"{"detail":"Invalid API key format"}"#)
        defer { malformed.stop() }
        XCTAssertThrowsError(try service(malformed).check()) { XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .badKey) }
        XCTAssertThrowsError(try service(malformed).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .badKey)
        }
        XCTAssertNoThrow(try service(good).check())
        XCTAssertTrue(try XCTUnwrap(good.requests.last).head.hasPrefix("GET /v1/credits"))
    }

    /// Moderation, out of credits and a rate limit come back in plain words, never naming Draw
    /// Things (that would send people to its setup steps).
    func testRefusalsAndLimitsInPlainWords() throws {
        let refused = try Self.fake(status: "Request Moderated", details: #"{"Moderation Reasons":["Violence"]}"#)
        defer { refused.stop() }
        XCTAssertThrowsError(try service(refused).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .refused(["Violence"]))
            XCTAssertTrue("\($0)".contains("wouldn't make this picture (violence)"), "\($0)")
        }
        for (code, error) in [(402, OnlineImagesError.Problem.noCredits), (429, .busy)] {
            let server = try Self.fake(submit: code)
            defer { server.stop() }
            XCTAssertThrowsError(try service(server).draw(description: "a dwarf", seed: 1, kind: .character)) {
                XCTAssertEqual(($0 as? OnlineImagesError)?.problem, error)
            }
        }
        for p in [OnlineImagesError.Problem.noKey, .badKey, .noCredits, .busy, .refused([]), .timedOut, .failed("x")] {
            let e = OnlineImagesError(p, service: OnlineService.bfl.name)
            XCTAssertFalse(e.description.contains("Draw Things"), e.description)
        }
    }

    /// Stop while it waits for the picture ends it at once; a Stop before the request is kept
    /// (#170), and nothing is sent.
    func testStop() throws {
        let server = try Self.fake(pending: .max)
        defer { server.stop() }
        let s = service(server)
        s.timeout = 3  // a Stop that doesn't stop it ends as timed out, not cancelled
        DispatchQueue.global().async {
            _ = eventually { server.requests.count >= 2 }
            s.cancel()
        }
        let started = Date()
        XCTAssertThrowsError(try s.draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let before = try Self.fake()
        defer { before.stop() }
        let early = service(before)
        early.cancel()
        XCTAssertThrowsError(try early.draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .cancelled)
        }
        XCTAssertTrue(before.requests.isEmpty, "a picture was asked for after Stop")
        early.reset()
        XCTAssertEqual(Self.size(try early.draw(description: "a dwarf", seed: 1, kind: .character)), [1024, 1024])
    }

    /// The picture is paid for once submitted: a busy moment while asking whether it's ready is
    /// asked again, not given up on. A task BFL doesn't know (a 404 "Task not found") is final.
    func testAHiccupWhileWaitingIsAskedAgain() throws {
        let busy = try Self.fake(hiccups: 2)
        defer { busy.stop() }
        XCTAssertEqual(Self.size(try service(busy).draw(description: "a dwarf", seed: 1, kind: .character)), [1024, 1024])
        // A dropped connection (Wi-Fi going for a moment) is asked again too, not taken as no internet.
        let dropped = try Self.fake(hiccups: 6, hiccup: 0)  // URLSession tries a dropped GET three times itself
        defer { dropped.stop() }
        XCTAssertEqual(Self.size(try service(dropped).draw(description: "a dwarf", seed: 1, kind: .character)), [1024, 1024])
        let lost = try Self.fake(status: "Task not found")
        defer { lost.stop() }
        XCTAssertThrowsError(try service(lost).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .failed(""))
        }
        XCTAssertEqual(lost.requests.filter { $0.head.contains("get_result") }.count, 1)
    }

    /// Stop on a mini whose picture is being made online stops the request, and the new mini goes
    /// to the Trash, as with Draw Things.
    func testStopDuringAJobStopsTheOnlineRequest() throws {
        let server = try Self.fake(pending: .max)
        defer { server.stop() }
        let fx = try Fixture(); try fx.modelFiles()
        let online = service(server)
        online.timeout = 5  // a Stop that doesn't reach it ends as timed out, not stopped
        let trashed = TrashSpy()
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { trashed($0) })
        jobs.pictureService = { online }
        try jobs.make(name: "dwarf", picture: .description("a dwarf"), restyle: false, seed: 1, sizes: Sizes(), model: EngineDownload.standard)
        XCTAssertTrue(eventually { server.requests.filter { $0.head.contains("get_result") }.count >= 2 })
        let started = Date()
        XCTAssertTrue(jobs.cancel())
        jobs.waitUntilDone()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Stop waited for the picture")
        XCTAssertEqual(jobs.status?.canceled, true)
        XCTAssertEqual(trashed.trashed.map(\.lastPathComponent), ["dwarf"])
    }

    func testAPictureThatNeverComesTimesOut() throws {
        let server = try Self.fake(pending: .max)
        defer { server.stop() }
        let s = service(server)
        s.timeout = 0.3
        XCTAssertThrowsError(try s.draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(($0 as? OnlineImagesError)?.problem, .timedOut)
        }
    }

    /// A redirect elsewhere is followed without the key: URLSession would carry it along.
    func testARedirectElsewhereDoesNotTakeTheKey() throws {
        let elsewhere = try FakeLLM(status: 200, body: #"{"credits":1}"#)
        defer { elsewhere.stop() }
        let bfl = try FakeLLM { _ in (302, Data("http://localhost:\(elsewhere.port)/v1/credits".utf8)) }
        defer { bfl.stop() }
        try service(bfl).check()
        let followed = try XCTUnwrap(elsewhere.requests.first, "the redirect wasn't followed")
        XCTAssertFalse(followed.head.lowercased().contains("x-key"), "the key went to another address")
        XCTAssertFalse(service(bfl).sendsKey(to: URL(string: "http://127.0.0.1:\(elsewhere.port)/")!), "another port is another address")
    }

    /// An error that echoes the key never shows it, even where the text is cut short.
    func testTheKeyIsNeverInAnErrorMessage() throws {
        let key = "k-1234567890"
        let server = try FakeLLM(status: 400, body: String(repeating: "x", count: 195) + key)
        defer { server.stop() }
        XCTAssertThrowsError(try service(server, key: key).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertFalse("\($0)".contains("k-12"), "\($0)")
        }
    }

    /// The key only goes to BFL's own hosts, or the address it was set up with.
    func testTheKeyOnlyGoesToBFL() {
        let s = BlackForestLabs(key: { "k" })
        XCTAssertTrue(s.sendsKey(to: URL(string: "https://api.us1.bfl.ai/v1/get_result?id=1")!))
        XCTAssertTrue(s.sendsKey(to: URL(string: "https://api.bfl.ai/v1/get_result?id=1")!))
        XCTAssertFalse(s.sendsKey(to: URL(string: "http://api.bfl.ai/v1/get_result")!))
        XCTAssertFalse(s.sendsKey(to: URL(string: "https://bfl.ai.example.com/x")!))
    }

    /// Draw Things stays the default; the online service is chosen in Settings.
    func testTheSettingDefaultsToDrawThings() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "mimic-test-\(UUID().uuidString)"))
        XCTAssertNil(OnlineService.configured(defaults: d))
        d.set("bfl", forKey: ImageService.key)
        XCTAssertNotNil(OnlineService.configured(defaults: d))
    }

    /// With the online service, Settings checks its key instead of Draw Things, which isn't needed:
    /// a wrong key is named, and a good one is green.
    func testChecksAskForTheKeyNotDrawThings() throws {
        let fx = try Fixture()
        let bad = try Self.fake(submit: 401)
        defer { bad.stop() }
        func checks(_ server: FakeLLM, key: String? = "k") -> [CheckResult] {
            Checks(install: fx.install, model: EngineDownload.standard, appFolders: [], drawThings: fx.noDrawThings(), autoOpen: false,
                   online: service(server, key: key), run: { _, _, _ in nil }, freeBytes: { _ in 0 }).all.map { $0.run() }
        }
        let wrong = checks(bad)
        XCTAssertFalse(wrong.contains { Checks.drawThingsIDs.contains($0.id) }, "Draw Things isn't needed")
        let key = try XCTUnwrap(wrong.first { $0.id == Checks.onlineID })
        XCTAssertFalse(key.ok)
        XCTAssertEqual(key.fix, OnlineImagesError(.badKey, service: "Black Forest Labs").description)
        XCTAssertFalse(key.required, "pictures you have still work without it")
        XCTAssertEqual(checks(bad, key: nil).first { $0.id == Checks.onlineID }?.fix, OnlineImagesError(.noKey, service: "Black Forest Labs").description)
        let good = try Self.fake()
        defer { good.stop() }
        XCTAssertEqual(checks(good).first { $0.id == Checks.onlineID }?.ok, true)
    }

    /// A description made through the online service: its picture is the service's, and Draw
    /// Things (the fixture's fails at once) is never asked.
    func testAJobMakesItsPictureOnline() throws {
        let server = try Self.fake()
        defer { server.stop() }
        let fx = try Fixture(); try fx.modelFiles()
        let online = service(server)
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/false"), trash: { _ in })
        jobs.pictureService = { online }
        try jobs.make(name: "dwarf", picture: .description("a dwarf"), restyle: false, seed: 1, sizes: Sizes(), model: EngineDownload.standard)
        jobs.waitUntilDone()
        XCTAssertEqual(Self.size(try Data(contentsOf: fx.install.runs.appendingPathComponent("dwarf/source.png"))), [1024, 1024])
    }

    /// A refused redraw leaves the mini as it was, and says why in plain words.
    func testARefusedRedrawLeavesTheMiniAlone() throws {
        let server = try Self.fake(status: "Content Moderated")
        defer { server.stop() }
        let fx = try Fixture(); try fx.modelFiles()
        let online = service(server)
        let jobs = JobRunner(install: fx.install, tools: fx.tools(mimic: "/usr/bin/true"), trash: { _ in })
        jobs.pictureService = { online }
        try jobs.make(name: "dwarf", picture: .image(try fx.picture()), restyle: true, seed: 1, sizes: Sizes(), model: EngineDownload.standard)
        jobs.waitUntilDone()
        let folder = fx.install.runs.appendingPathComponent("dwarf")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
        XCTAssertFalse(files.contains("source.png"), "no picture was made")
        XCTAssertTrue(MiniSettings.load(folder).failed?.contains("wouldn't make this picture") == true, "\(MiniSettings.load(folder).failed ?? "nil")")
        // Try Again, refused again: nothing it had changes.
        try jobs.retry(name: "dwarf")
        jobs.waitUntilDone()
        for f in files where f != "settings.json" && !f.hasSuffix(".log") {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(f)), before[f], f)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a failed mini is kept, not thrown away")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
