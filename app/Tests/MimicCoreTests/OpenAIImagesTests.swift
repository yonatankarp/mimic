import XCTest
@testable import MimicCore

/// OpenAI as the online picture service (#247), against a local stand-in for its Image API: one
/// request a picture, which comes back in the reply.
final class OpenAIImagesTests: XCTestCase {
    /// A fake OpenAI: generations and edits answer `status` with `body` (the picture by default),
    /// after waiting on `hold` (up to 5 s) when given; /v1/models answers `check` with `checkBody`.
    static func fake(status: Int = 200, body: String? = nil, check: Int = 200, checkBody: String = #"{"object":"list","data":[]}"#,
                     hold: DispatchSemaphore? = nil) throws -> FakeLLM {
        let picture = #"{"created":1,"data":[{"b64_json":"\#(OnlineImagesTests.picture.base64EncodedString())"}]}"#
        return try FakeLLM { r in
            let path = r.head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if path.hasPrefix("/v1/images/") {
                _ = hold?.wait(timeout: .now() + 5)
                return (status, Data((body ?? picture).utf8))
            }
            if path == "/v1/models" { return (check, Data(checkBody.utf8)) }
            return (404, Data())
        }
    }

    private func service(_ server: FakeLLM, key: String? = "k-123") -> OpenAIImages {
        OpenAIImages(base: URL(string: "http://127.0.0.1:\(server.port)")!, key: { key })
    }

    private func problem(_ e: Error) -> OnlineImagesError.Problem? { (e as? OnlineImagesError)?.problem }

    /// Text to picture: today's prompt, the pinned model, a square PNG, the key as a bearer token,
    /// and the picture in the reply, at the size Draw Things makes.
    func testDrawsFromADescription() throws {
        let server = try Self.fake()
        defer { server.stop() }
        let png = try service(server).draw(description: "stout dwarf", seed: 7, kind: .character)
        XCTAssertEqual(OnlineImagesTests.size(png), [1024, 1024], "the 8 × 8 the service sent, at the size Draw Things makes")
        let r = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(r.head.hasPrefix("POST /v1/images/generations "), r.head)
        XCTAssertTrue(r.head.lowercased().contains("authorization: bearer k-123"))
        let b = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any])
        XCTAssertEqual(b["model"] as? String, "gpt-image-2.5-sunburst")
        XCTAssertEqual(b["prompt"] as? String, DrawThings.drawPrompt("stout dwarf", kind: .character))
        XCTAssertEqual(b["size"] as? String, "1024x1024")
        XCTAssertEqual(b["output_format"] as? String, "png")
        XCTAssertNil(b["seed"], "the Image API takes no seed")
    }

    /// Picture to picture: an edit, sent as a form with the picture as a PNG file, the sculpt
    /// prompt with the change, at Draw Things' edit size.
    func testRedrawsAPictureAsASculpt() throws {
        let server = try Self.fake()
        defer { server.stop() }
        let fx = try Fixture()
        let png = try service(server).sculpt(picture: try fx.picture(), seed: 3, kind: .object, change: "a taller lid")
        let (w, h) = DrawThings.editSize(width: 8, height: 8)
        XCTAssertEqual(OnlineImagesTests.size(png), [w, h])
        let r = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(r.head.hasPrefix("POST /v1/images/edits "), r.head)
        XCTAssertTrue(r.head.lowercased().contains("content-type: multipart/form-data; boundary="), r.head)
        XCTAssertTrue(r.head.lowercased().contains("authorization: bearer k-123"))
        func field(_ name: String) -> String? {
            r.body.components(separatedBy: "name=\"\(name)\"\r\n\r\n").dropFirst().first?.components(separatedBy: "\r\n").first
        }
        XCTAssertEqual(field("prompt"), DrawThings.redrawPrompt(kind: .object, change: "a taller lid"))
        XCTAssertEqual(field("model"), OpenAIImages.model)
        XCTAssertEqual(field("size"), "\(w)x\(h)")
        XCTAssertEqual(field("output_format"), "png")
        XCTAssertTrue(r.body.contains("name=\"image[]\"; filename=\"picture.png\"\r\nContent-Type: image/png\r\n\r\n"), "the picture goes as a file")
        XCTAssertTrue(r.body.contains("IHDR"), "the picture goes as a PNG")
    }

    /// The size asked for is the one wanted when the model takes it; otherwise the nearest of its
    /// usual three, the same shape, since what comes back is stretched to the size wanted.
    func testTheSizeAskedFor() {
        XCTAssertEqual(OpenAIImages.size(width: 1024, height: 1024), "1024x1024")
        XCTAssertEqual(OpenAIImages.size(width: 1536, height: 1152), "1536x1152")
        // Wider or taller than 3:1: the nearest the model takes, 3:1, not a squashed 3:2.
        XCTAssertEqual(OpenAIImages.size(width: 1536, height: 448), "1536x512")
        XCTAssertEqual(OpenAIImages.size(width: 448, height: 1536), "512x1536")
        XCTAssertEqual(OpenAIImages.size(width: 512, height: 512), "1536x1536", "too few pixels: the same shape, larger")
        XCTAssertEqual(OpenAIImages.size(width: 1600, height: 1000), "1536x960", "not in sixteens: the same shape")
    }

    /// No key: nothing is sent. A key turned down (a 401, seen live for a made-up key) says so, in
    /// Settings' Test too, and never shows the part of the key OpenAI's message repeats.
    func testAMissingOrWrongKey() throws {
        let incorrect = #"{"error":{"message":"Incorrect API key provided: k-12***23.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        let wrong = try Self.fake(status: 401, body: incorrect, check: 401, checkBody: incorrect)
        defer { wrong.stop() }
        XCTAssertThrowsError(try service(wrong, key: " ").draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(problem($0), .noKey)
        }
        XCTAssertTrue(wrong.requests.isEmpty)
        XCTAssertThrowsError(try service(wrong).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(problem($0), .badKey)
            XCTAssertFalse("\($0)".contains("k-12"), "\($0)")
        }
        XCTAssertThrowsError(try service(wrong).check()) { XCTAssertEqual(problem($0), .badKey) }
    }

    /// The key check lists the models, which costs nothing.
    func testTheKeyCheckIsFree() throws {
        let server = try Self.fake()
        defer { server.stop() }
        XCTAssertNoThrow(try service(server).check())
        let r = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(r.head.hasPrefix("GET /v1/models "), r.head)
        XCTAssertTrue(r.head.lowercased().contains("authorization: bearer k-123"))
    }

    /// A safety refusal, a rate limit, an empty account and a server error come back in plain
    /// words; anything else in OpenAI's own words, such as a model the account can't use yet.
    func testRefusalsAndLimitsInPlainWords() throws {
        let refused = try Self.fake(status: 400, body: #"{"error":{"message":"Your request was rejected by the safety system.","type":"image_generation_user_error","code":"moderation_blocked","moderation_details":{"moderation_stage":"input","categories":["violence"]}}}"#)
        defer { refused.stop() }
        XCTAssertThrowsError(try service(refused).draw(description: "a dwarf", seed: 1, kind: .character)) {
            XCTAssertEqual(problem($0), .refused(["violence"]))
            XCTAssertEqual("\($0)", "OpenAI wouldn't make this picture (violence). Try different words or another picture.")
        }
        let verify = "Your organization must be verified to use the model."
        let scopes = "You have insufficient permissions for this operation. Missing scopes: api.model.images.request."
        // Status, error type, error code, message, and what it means. Billing errors, from OpenAI's
        // error codes guide: the code says which, and the type may still be insufficient_quota.
        let cases: [(Int, String, String, String, OnlineImagesError.Problem)] = [
            (429, "requests", "rate_limit_exceeded", "", .busy),
            (429, "insufficient_quota", "insufficient_quota", "", .noCredits),
            (429, "insufficient_quota", "credit_balance_exhausted", "", .noCredits),
            (429, "", "credit_balance_exhausted", "", .noCredits),
            (429, "", "organization_spend_limit_exceeded", "", .noCredits),
            (429, "", "project_spend_limit_exceeded", "", .noCredits),
            (429, "", "organization_usage_limit_exceeded", "", .noCredits),
            (503, "", "", "", .busy),
            (403, "", "", verify, .failed(verify)),
            // A 401 that isn't a wrong key, in OpenAI's words: a restricted key without the scope.
            (401, "invalid_request_error", "", scopes, .failed(scopes)),
        ]
        for (status, type, code, message, expected) in cases {
            let server = try Self.fake(status: status, body: #"{"error":{"message":"\#(message)","type":"\#(type)","code":"\#(code)"}}"#)
            defer { server.stop() }
            XCTAssertThrowsError(try service(server).draw(description: "a dwarf", seed: 1, kind: .character), "\(status) \(code)") {
                XCTAssertEqual(problem($0), expected, "\(status) \(type) \(code)")
            }
        }
        XCTAssertTrue(OnlineImagesError(.noCredits, service: "OpenAI").description.contains("raise your limit"))
    }

    /// A restricted key allowed to make pictures but not to list models is turned down by the free
    /// check with a 401 naming the missing scope: it's a key OpenAI knows, so the check passes, and
    /// descriptions and the sculpt stay on. Any other 401 there says why, in OpenAI's words.
    func testTheCheckPassesARestrictedKey() throws {
        let restricted = try Self.fake(check: 401, checkBody: #"{"error":{"message":"You have insufficient permissions for this operation. Missing scopes: api.model.read. Check that you have the correct role in your organization (Reader, Writer, Owner) and project (Member, Owner), and if you're using a restricted API key, that it has the necessary scopes.","type":"invalid_request_error","param":null,"code":null}}"#)
        defer { restricted.stop() }
        XCTAssertNoThrow(try service(restricted).check())
        let ip = "IP not authorized for this project."
        let elsewhere = try Self.fake(check: 401, checkBody: #"{"error":{"message":"\#(ip)","type":"invalid_request_error","code":null}}"#)
        defer { elsewhere.stop() }
        XCTAssertThrowsError(try service(elsewhere).check()) { XCTAssertEqual(problem($0), .failed(ip)) }
    }

    /// Stop while the picture is being made ends the request at once; a Stop before it is kept
    /// (#170), and nothing is sent.
    func testStop() throws {
        let hold = DispatchSemaphore(value: 0)
        let server = try Self.fake(hold: hold)
        defer { hold.signal(); server.stop() }
        let s = service(server)
        DispatchQueue.global().async {
            _ = eventually { !server.requests.isEmpty }
            s.cancel()
        }
        let started = Date()
        XCTAssertThrowsError(try s.draw(description: "a dwarf", seed: 1, kind: .character)) { XCTAssertEqual(problem($0), .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "Stop waited for the picture")

        let before = try Self.fake()
        defer { before.stop() }
        let early = service(before)
        early.cancel()
        XCTAssertThrowsError(try early.sculpt(picture: try Fixture().picture(), seed: 1, kind: .character, change: nil)) {
            XCTAssertEqual(problem($0), .cancelled)
        }
        XCTAssertTrue(before.requests.isEmpty, "a picture was asked for after Stop")
    }

    func testAPictureThatNeverComesTimesOut() throws {
        let hold = DispatchSemaphore(value: 0)
        let server = try Self.fake(hold: hold)
        defer { hold.signal(); server.stop() }
        let s = service(server)
        s.timeout = 0.5
        XCTAssertThrowsError(try s.draw(description: "a dwarf", seed: 1, kind: .character)) { XCTAssertEqual(problem($0), .timedOut) }
    }

    /// The key goes to api.openai.com over https, or the address it was set up with, and nowhere
    /// else: a redirect elsewhere is followed without it.
    func testTheKeyOnlyGoesToOpenAI() throws {
        let s = OpenAIImages(key: { "k" })
        XCTAssertTrue(s.sendsKey(to: URL(string: "https://api.openai.com/v1/models")!))
        XCTAssertFalse(s.sendsKey(to: URL(string: "http://api.openai.com/v1/models")!))
        XCTAssertFalse(s.sendsKey(to: URL(string: "https://api.openai.com.example.com/v1/models")!))
        XCTAssertFalse(s.sendsKey(to: URL(string: "https://files.openai.com/x")!))
        XCTAssertFalse(s.sendsKey(to: URL(string: "https://api.bfl.ai/v1/credits")!), "another service's host")

        let elsewhere = try FakeLLM(status: 200, body: #"{"data":[]}"#)
        defer { elsewhere.stop() }
        let openai = try FakeLLM { _ in (302, Data("http://localhost:\(elsewhere.port)/v1/models".utf8)) }
        defer { openai.stop() }
        try service(openai).check()
        let followed = try XCTUnwrap(elsewhere.requests.first, "the redirect wasn't followed")
        XCTAssertFalse(followed.head.lowercased().contains("authorization"), "the key went to another address")
    }

    /// URLSession drops Authorization on a redirect to another host by itself (above, it passes
    /// either way), so the guard is asked directly: it takes out the header the service's key is in.
    func testARedirectElsewhereLosesTheKeyHeader() async throws {
        let s = OpenAIImages(key: { "k" })
        var r = URLRequest(url: URL(string: "https://example.com/v1/models")!)
        r.setValue("Bearer k", forHTTPHeaderField: "Authorization")
        let guardKey = KeepKey(header: s.service.keyHeader) { s.sendsKey(to: $0) }
        let redirect = try XCTUnwrap(HTTPURLResponse(url: s.base, statusCode: 302, httpVersion: nil, headerFields: nil))
        let task = URLSession.shared.dataTask(with: r)
        let elsewhere = await guardKey.urlSession(.shared, task: task, willPerformHTTPRedirection: redirect, newRequest: r)
        XCTAssertNil(elsewhere?.value(forHTTPHeaderField: "Authorization"))
        r.url = URL(string: "https://api.openai.com/v1/models")
        let own = await guardKey.urlSession(.shared, task: task, willPerformHTTPRedirection: redirect, newRequest: r)
        XCTAssertEqual(own?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    /// Choosing OpenAI in Settings gives its client, with its own Keychain account: not the
    /// description helper's "openai", nor Black Forest Labs'.
    func testTheSettingPicksOpenAI() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "mimic-test-\(UUID().uuidString)"))
        d.set("openai", forKey: ImageService.key)
        XCTAssertTrue(OnlineService.configured(defaults: d) is OpenAIImages)
        let accounts = ImageService.allCases.compactMap(\.online?.keyAccount)
        XCTAssertEqual(Set(accounts).count, accounts.count)
        XCTAssertFalse(accounts.contains(HelperProvider.openai.rawValue), "the helper's key would be shared")
    }

    /// Every message, the check's label and the report name the chosen service and no other one:
    /// the app shows them as they are, so one service's name can't leak into another's.
    func testEachServiceNamesOnlyItself() throws {
        let services = ImageService.allCases.compactMap(\.online)
        XCTAssertEqual(services.map(\.name), ["Black Forest Labs", "OpenAI"])
        let problems: [OnlineImagesError.Problem] = [.noKey, .badKey, .noCredits, .busy, .refused([]), .refused(["violence"]), .timedOut,
                                                     .unreachable, .failed(""), .failed("x")]
        for s in services {
            var report = ReportSetup(model: "m")
            report.pictures = try XCTUnwrap(ImageService.allCases.first { $0.online?.name == s.name })
            var said = problems.map { OnlineImagesError($0, service: s.name).description }
            said += [Checks.onlineLabel(s), try XCTUnwrap(report.rows(home: "/x").first { $0.0 == "Draw Things" }?.1)]
            // What its client throws, as a job or Settings' Test shows it.
            let client = s.client(base: URL(string: "http://127.0.0.1:1")!) { nil }
            XCTAssertThrowsError(try client.check()) { said.append("\($0)") }
            for text in said {
                XCTAssertTrue(text.contains(s.name), text)
                for other in services.map(\.name) + ["Draw Things"] where other != s.name {
                    XCTAssertFalse(text.contains(other), "\(s.name): \(text)")
                }
            }
        }
    }
}
