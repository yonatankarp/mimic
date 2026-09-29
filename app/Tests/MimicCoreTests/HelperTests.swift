import Foundation
import XCTest
@testable import MimicCore

/// The AI helper for Describe it. No network: requests are checked as built, replies parsed from
/// the shapes each provider documents, and end-to-end calls go to a local fake server.
final class HelperTests: XCTestCase {
    static let key = "sk-test-DO-NOT-LEAK-1234567890"

    func helper(_ p: HelperProvider, base: String? = nil, model: String? = nil, key: String? = HelperTests.key) -> DescriptionHelper {
        DescriptionHelper(config: HelperConfig(provider: p, model: model, baseURL: base), key: key)
    }

    func json(_ req: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    // MARK: Requests

    func testAnthropicRequest() throws {
        let req = try helper(.anthropic).request(system: "S", user: "a dwarf", maxTokens: 400)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), Self.key)
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = try json(req)
        XCTAssertEqual(b["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(b["max_tokens"] as? Int, 400)
        XCTAssertEqual(b["system"] as? String, "S")
        XCTAssertEqual(b["messages"] as? [[String: String]], [["role": "user", "content": "a dwarf"]])
        XCTAssertNil(b["thinking"], "Haiku takes no thinking settings here")
    }

    func testOpenAIRequest() throws {
        let req = try helper(.openai, base: "https://example.com/v1/", model: "some-model").request(system: "S", user: "a dwarf", maxTokens: 400)
        XCTAssertEqual(req.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.key)")
        let b = try json(req)
        XCTAssertEqual(Set(b.keys), ["model", "messages"], "only what every compatible service accepts")
        XCTAssertEqual(b["messages"] as? [[String: String]], [["role": "system", "content": "S"], ["role": "user", "content": "a dwarf"]])
    }

    func testOllamaRequestNeedsNoKey() throws {
        let req = try helper(.ollama, model: "gemma3:1b", key: nil).request(system: "S", user: "a dwarf", maxTokens: 5)
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let b = try json(req)
        XCTAssertEqual(b["stream"] as? Bool, false)
        XCTAssertEqual(b["think"] as? Bool, false, "thinking models otherwise reason for minutes first")
        XCTAssertEqual((b["options"] as? [String: Int])?["num_predict"], 5)
    }

    func testMissingPiecesAreSaidBeforeAnyCall() {
        XCTAssertThrowsError(try helper(.anthropic, key: nil).request(system: "", user: "", maxTokens: 1)) { XCTAssertEqual($0 as? HelperError, .noKey) }
        XCTAssertThrowsError(try helper(.openai).request(system: "", user: "", maxTokens: 1)) { XCTAssertEqual($0 as? HelperError, .noModel(.openai)) }
        XCTAssertThrowsError(try helper(.ollama, key: nil).request(system: "", user: "", maxTokens: 1)) { XCTAssertEqual($0 as? HelperError, .noModel(.ollama)) }
        XCTAssertThrowsError(try helper(.openai, base: "not a url", model: "m").request(system: "", user: "", maxTokens: 1)) { XCTAssertEqual($0 as? HelperError, .badURL) }
    }

    // MARK: Replies

    func testParsesEachProvidersReply() throws {
        let anthropic = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"stout dwarf"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try DescriptionHelper.parse(.anthropic, model: "m", status: 200, data: Data(anthropic.utf8)), "stout dwarf")
        let openai = #"{"choices":[{"message":{"role":"assistant","content":"tall elf"}}]}"#
        XCTAssertEqual(try DescriptionHelper.parse(.openai, model: "m", status: 200, data: Data(openai.utf8)), "tall elf")
        let ollama = #"{"message":{"role":"assistant","content":"grim orc"},"done":true}"#
        XCTAssertEqual(try DescriptionHelper.parse(.ollama, model: "m", status: 200, data: Data(ollama.utf8)), "grim orc")
    }

    func testErrorBodiesBecomePlainWords() {
        func err(_ p: HelperProvider, _ status: Int, _ body: String) -> HelperError? {
            do { _ = try DescriptionHelper.parse(p, model: "llama9", status: status, data: Data(body.utf8)); return nil } catch { return error as? HelperError }
        }
        XCTAssertEqual(err(.anthropic, 401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#), .badKey)
        XCTAssertEqual(err(.anthropic, 529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), .busy)
        XCTAssertEqual(err(.anthropic, 400, #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#), .refused("prompt is too long"))
        XCTAssertEqual(err(.anthropic, 200, #"{"content":[],"stop_reason":"refusal"}"#), .refused("the model declined this description"))
        XCTAssertEqual(err(.openai, 429, #"{"error":{"message":"Rate limit reached"}}"#), .busy)
        XCTAssertEqual(err(.openai, 404, #"{"error":{"message":"The model `llama9` does not exist"}}"#), .modelMissing("llama9", .openai))
        XCTAssertEqual(err(.ollama, 404, #"{"error":"model 'llama9' not found"}"#), .modelMissing("llama9", .ollama))
        XCTAssertEqual(err(.ollama, 200, #"{"message":{"content":""}}"#), .empty)
        XCTAssertTrue(HelperError.modelMissing("llama9", .ollama).description.contains("ollama pull llama9"), "the fix is in the message")
    }

    /// The answer goes after "…miniature of a", so a leading article, quotes or thinking don't belong.
    func testCleansTheAnswer() {
        XCTAssertEqual(DescriptionHelper.clean("<think>hmm\nok</think>\n\"A stout dwarf,\n  broad shoulders.\""), "stout dwarf, broad shoulders.")
        XCTAssertEqual(DescriptionHelper.clean("the grim orc"), "grim orc")
        XCTAssertEqual(DescriptionHelper.clean("Miniature of a stout dwarf"), "stout dwarf", "gemma3 repeats the lead-in")
        XCTAssertEqual(DescriptionHelper.clean("anvil-bearing dwarf"), "anvil-bearing dwarf", "only a whole word is an article")
    }

    func testOllamaTags() {
        let tags = #"{"models":[{"name":"gemma3:4b","size":1},{"name":"gemma3:1b","size":2}]}"#
        XCTAssertEqual(DescriptionHelper.parseTags(Data(tags.utf8)), ["gemma3:1b", "gemma3:4b"])
        XCTAssertEqual(DescriptionHelper.parseTags(Data("{}".utf8)), [])
    }

    // MARK: Against a local server

    func testEndToEndPerProvider() throws {
        let replies: [(HelperProvider, String)] = [
            (.anthropic, #"{"content":[{"type":"text","text":"A stout dwarf blacksmith"}],"stop_reason":"end_turn"}"#),
            (.openai, #"{"choices":[{"message":{"content":"stout dwarf blacksmith"}}]}"#),
            (.ollama, #"{"message":{"content":"stout dwarf blacksmith"}}"#),
        ]
        for (p, body) in replies {
            let server = try FakeLLM(body: body)
            defer { server.stop() }
            let h = helper(p, base: "http://127.0.0.1:\(server.port)", model: "m", key: p.isCloud ? Self.key : nil)
            XCTAssertEqual(try h.improve("a grumpy dwarf blacksmith"), "stout dwarf blacksmith", "\(p)")
            let got = try XCTUnwrap(server.requests.first)
            XCTAssertTrue(got.body.contains("a grumpy dwarf blacksmith"), "\(p): the description is sent")
            XCTAssertTrue(got.body.contains("ONE figure"), "\(p): with the system prompt")
            XCTAssertEqual(got.head.contains(Self.key), p.isCloud, "\(p): the key goes only where it's needed")
        }
    }

    /// Whatever goes wrong, the key never shows up in what people or logs see.
    func testTheKeyNeverAppearsInAnError() throws {
        for (status, body) in [(401, #"{"error":{"message":"Incorrect API key provided: \#(Self.key)"}}"#),
                               (400, #"{"error":{"message":"bad key \#(Self.key)"}}"#),
                               (500, "\(Self.key)")] {
            let server = try FakeLLM(status: status, body: body)
            defer { server.stop() }
            XCTAssertThrowsError(try helper(.openai, base: "http://127.0.0.1:\(server.port)", model: "m").improve("x")) {
                XCTAssertFalse("\($0)".contains(Self.key), "status \(status): \($0)")
            }
        }
    }

    func testNothingListeningIsNamedByProvider() {
        XCTAssertThrowsError(try helper(.ollama, base: "http://127.0.0.1:9", model: "m", key: nil).improve("x")) { XCTAssertEqual($0 as? HelperError, .notRunning) }
        XCTAssertThrowsError(try DescriptionHelper.ollamaModels(base: "http://127.0.0.1:9")) { XCTAssertEqual($0 as? HelperError, .notRunning) }
        XCTAssertThrowsError(try helper(.openai, base: "http://127.0.0.1:9", model: "m").improve("x")) { XCTAssertEqual($0 as? HelperError, .unreachable) }
    }

    /// Real Ollama, only when asked: MIMIC_LIVE_OLLAMA=gemma3:4b swift test --filter testLiveOllama
    func testLiveOllama() throws {
        guard let model = ProcessInfo.processInfo.environment["MIMIC_LIVE_OLLAMA"] else { throw XCTSkip("MIMIC_LIVE_OLLAMA not set") }
        let h = helper(.ollama, model: model, key: nil)
        XCTAssertTrue(try DescriptionHelper.ollamaModels().contains(model))
        try h.test()
        for idea in ["a grumpy dwarf blacksmith", "elf archer", "a goblin with a lantern"] {
            let started = Date()
            let out = try h.improve(idea)
            print("LIVE \(idea) (\(Int(Date().timeIntervalSince(started)))s, \(out.split(separator: " ").count) words): \(out)")
            XCTAssertFalse(out.isEmpty)
        }
        XCTAssertThrowsError(try helper(.ollama, model: "no-such-model", key: nil).improve("x")) {
            XCTAssertEqual($0 as? HelperError, .modelMissing("no-such-model", .ollama))
        }
    }

    // MARK: Keychain and settings

    func testKeychainRoundTrip() throws {
        let service = "com.mimic.app.tests.\(UUID().uuidString)"
        defer { Keychain.delete(account: "anthropic", service: service) }
        XCTAssertNil(Keychain.read(account: "anthropic", service: service))
        XCTAssertFalse(Keychain.has(account: "anthropic", service: service))
        try Keychain.save("first", account: "anthropic", service: service)
        try Keychain.save("second", account: "anthropic", service: service)
        XCTAssertEqual(Keychain.read(account: "anthropic", service: service), "second", "saving again replaces")
        XCTAssertTrue(Keychain.has(account: "anthropic", service: service))
        let suite = "mimic-test-\(UUID().uuidString)", d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set("anthropic", forKey: HelperConfig.providerKey)
        let h = try XCTUnwrap(DescriptionHelper.configured(defaults: d, service: service))
        XCTAssertEqual(h.key, "second")
        XCTAssertNil(d.dictionaryRepresentation().values.first { "\($0)".contains("second") }, "the key is not in the defaults")
        Keychain.delete(account: "anthropic", service: service)
        XCTAssertNil(Keychain.read(account: "anthropic", service: service))
    }

    func testOffUnlessChosen() throws {
        let suite = "mimic-test-\(UUID().uuidString)", d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(DescriptionHelper.configured(defaults: d))
        d.set("ollama", forKey: HelperConfig.providerKey)
        d.set("", forKey: HelperConfig.urlKey)
        XCTAssertEqual(DescriptionHelper.configured(defaults: d)?.config, HelperConfig(provider: .ollama), "blank means the default")
    }

    func testSettingsKeepBothDescriptions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MiniSettings.update(folder) { $0.source = .desc; $0.desc = "a dwarf" }
        var raw = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("descOriginal"), "not improved: the file is what it was before the helper")
        try MiniSettings.update(folder) { $0.desc = "stout dwarf"; $0.descOriginal = "a dwarf" }
        raw = try String(contentsOf: folder.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains(#""descOriginal" : "a dwarf""#))
        XCTAssertEqual(MiniSettings.load(folder).descOriginal, "a dwarf")
    }

    /// An object gets its own brief: one whole object, no figure words, the same length and
    /// the same noun-phrase answer; the object's kind reaches the request.
    func testAnObjectHasItsOwnPrompt() throws {
        let object = DescriptionHelper.systemPrompt(kind: "object"), character = DescriptionHelper.systemPrompt(kind: "character")
        XCTAssertNotEqual(object, character)
        XCTAssertEqual(DescriptionHelper.systemPrompt(), character, "no kind is a character, as before object mode")
        for words in ["ONE object", "50 to 80 words", #""a ___""#, "no background", "with no article", "Reply with the description only"] {
            XCTAssertTrue(object.contains(words), words)
        }
        for words in ["figure", "miniature", "weapon"] { XCTAssertFalse(object.contains(words), words) }
        let server = try FakeLLM(body: #"{"message":{"content":"a squat cast-iron teapot"}}"#)
        defer { server.stop() }
        let h = helper(.ollama, base: "http://127.0.0.1:\(server.port)", model: "m", key: nil)
        XCTAssertEqual(try h.improve("teapot", kind: "object"), "squat cast-iron teapot")
        XCTAssertTrue(try XCTUnwrap(server.requests.first).body.contains("ONE object"))
        XCTAssertTrue(DrawThings.drawPrompt("squat cast-iron teapot", kind: .object).hasPrefix("squat cast-iron teapot. "))
    }

    /// Try Again draws from the improved text saved with the mini, and never asks the helper again.
    func testTryAgainNeverCallsTheHelper() throws {
        let server = try FakeLLM(body: #"{"message":{"content":"stout dwarf blacksmith"}}"#)
        defer { server.stop() }
        let improved = try helper(.ollama, base: "http://127.0.0.1:\(server.port)", model: "m", key: nil).improve("a dwarf")
        XCTAssertEqual(server.requests.count, 1)

        let f = try Fixture()
        let jobs = JobRunner(install: f.install, tools: f.tools(mimic: "/usr/bin/false"),
                             drawThings: DrawThings(environment: ["DRAWTHINGS_URL": "http://127.0.0.1:9", "DRAWTHINGS_MODEL": "x"], app: FakeApp().app, cli: nil))
        try f.modelFiles()
        try jobs.make(name: "dwarf", picture: .description(improved, original: "a dwarf"), restyle: false, seed: 1, sizes: Sizes(),
                      model: EngineDownload.standard)
        jobs.waitUntilDone()
        let folder = f.install.runs.appendingPathComponent("dwarf")
        let saved = MiniSettings.load(folder)
        XCTAssertEqual(saved.desc, "stout dwarf blacksmith")
        XCTAssertEqual(saved.descOriginal, "a dwarf")
        let plan = try Pipeline.plan(.generate, folder: folder, settings: saved, tools: Tools(mimic: "m", engine: "e", environment: [:]))
        XCTAssertEqual(plan.first?.step, .drawCharacter(description: "stout dwarf blacksmith", seed: 1, to: folder.appendingPathComponent("source.png")))
        try jobs.retry(name: "dwarf")
        jobs.waitUntilDone()
        XCTAssertEqual(server.requests.count, 1, "Try Again asked the helper again")
    }

    /// Effects don't print, and gemma3:4b adds them despite the prompt: these are its real replies.
    func testEffectsAreTakenOutAndTheRestKept() {
        let dwarf = "stout dwarf blacksmith with a grizzled face. His arms are bent, hammering a large, glowing metal ingot held close to his chest, sparks erupting around the blow. Thick leather gauntlets cover his hands."
        XCTAssertEqual(DescriptionHelper.dropEffects(dwarf),
                       "stout dwarf blacksmith with a grizzled face. His arms are bent, hammering a large metal ingot held close to his chest. Thick leather gauntlets cover his hands.")
        let hammer = "One hand grips a hefty warhammer, while the other holds a glowing forge hammer, sparks flying around it, a worn leather apron covers his torso."
        let kept = DescriptionHelper.dropEffects(hammer)
        XCTAssertFalse(kept.lowercased().contains("glow") || kept.lowercased().contains("spark"), kept)
        XCTAssertTrue(kept.contains("forge hammer") && kept.contains("leather apron"), "the real things stay: \(kept)")
        XCTAssertEqual(DescriptionHelper.dropEffects("tall elf archer with a longbow held close."), "tall elf archer with a longbow held close.",
                       "nothing to take out: unchanged")
        XCTAssertEqual(DescriptionHelper.dropEffects("lean ranger, light leather armour, a fire-red cloak."), "lean ranger, light leather armour, a fire-red cloak.",
                       "light armour and fire-red aren't effects")
        XCTAssertEqual(DescriptionHelper.dropEffects("The lantern, held close to his chest, illuminating his mischievous expression and simple boots."),
                       "The lantern, held close to his chest.", "a phrase led by a verb for light goes whole, from gemma3:4b")
    }

    func testTheBestInstalledOllamaModelIsSuggested() {
        XCTAssertEqual(DescriptionHelper.recommendedOllama(["gemma3:4b", "glm-4.7-flash:latest", "gemma4:latest"]), "gemma4:latest")
        XCTAssertEqual(DescriptionHelper.recommendedOllama(["glm-4.7-flash:latest", "gemma3:4b"]), "gemma3:4b")
        XCTAssertNil(DescriptionHelper.recommendedOllama(["glm-4.7-flash:latest"]), "not one we'd suggest")
    }

}

/// A local stand-in for an LLM API: reads each whole request (headers, then Content-Length bytes
/// of body, which URLSession may send separately), keeps it, and answers with `status` and `body`.
final class FakeLLM: @unchecked Sendable {
    struct Request { let head: String; let body: String }
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var got: [Request] = []
    var requests: [Request] { lock.withLock { got } }

    init(status: Int = 200, body: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in
            while case let c = accept(fd, nil, nil), c >= 0 {
                var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
                func more() -> Bool { let n = read(c, &buf, buf.count); if n > 0 { data.append(contentsOf: buf[0..<n]) }; return n > 0 }
                while data.range(of: Data("\r\n\r\n".utf8)) == nil, more() {}
                let split = data.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? data.endIndex
                let head = String(decoding: data[..<split], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                while data.count - split < length, more() {}
                lock.withLock { got.append(Request(head: head, body: String(decoding: data[split...], as: UTF8.self))) }
                let reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }

}
