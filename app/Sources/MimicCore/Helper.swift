import Foundation
import Security

/// The optional AI helper for ✍️ Describe it: turns "a grumpy dwarf blacksmith" into a fuller
/// description of one figure that prints well. Off unless someone picks a provider in Settings;
/// it only ever receives the description text.
public enum HelperProvider: String, CaseIterable, Sendable {
    case off, anthropic, openai, ollama

    public var isCloud: Bool { self == .anthropic || self == .openai }

    /// Haiku: the rewrite is short and easy, and the person waits for it in the sheet, so the
    /// fastest and cheapest Claude wins ($1/$5 per million tokens against Sonnet 5.5's $2/$10).
    /// OpenAI-compatible services name their models differently, and Ollama has what's installed.
    public var defaultModel: String { self == .anthropic ? "claude-haiku-4-5" : "" }

    public var defaultURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        case .openai: "https://api.openai.com/v1"
        case .ollama: "http://127.0.0.1:11434"
        case .off: ""
        }
    }
}

/// What Settings stores in UserDefaults (never the key): the same keys the app's @AppStorage uses,
/// so `mimic make --improve` through the PATH symlink reads the app's choice.
public struct HelperConfig: Equatable, Sendable {
    public static let providerKey = "helperProvider", modelKey = "helperModel", urlKey = "helperURL"
    public var provider: HelperProvider
    public var model: String
    public var baseURL: String

    public init(provider: HelperProvider, model: String? = nil, baseURL: String? = nil) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.baseURL = baseURL ?? provider.defaultURL
    }

    public static func load(_ d: UserDefaults) -> HelperConfig {
        let p = HelperProvider(rawValue: d.string(forKey: providerKey) ?? "") ?? .off
        func text(_ k: String) -> String? { d.string(forKey: k).flatMap { $0.isEmpty ? nil : $0 } }
        return HelperConfig(provider: p, model: text(modelKey), baseURL: text(urlKey))
    }
}

/// API keys live in the login Keychain as generic passwords: service "com.mimic.app", one account
/// per provider. Never in UserDefaults, settings.json or a log.
public enum Keychain {
    public static let service = "com.mimic.app"

    private static func query(_ account: String, _ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func read(account: String, service: String = service) -> String? {
        var q = query(account, service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ value: String, account: String, service: String = service) throws {
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(account, service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account, service)
            q[kSecValueData as String] = data
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HelperError.keychain(status) }
    }

    public static func delete(account: String, service: String = service) {
        SecItemDelete(query(account, service) as CFDictionary)
    }
}

public struct DescriptionHelper: Sendable {
    public let config: HelperConfig
    let key: String?

    public init(config: HelperConfig, key: String?) { self.config = config; self.key = key }

    /// The helper Settings chose, with its key from the Keychain; nil when it's off.
    public static func configured(defaults: UserDefaults, service: String = Keychain.service) -> DescriptionHelper? {
        let c = HelperConfig.load(defaults)
        guard c.provider != .off else { return nil }
        return DescriptionHelper(config: c, key: c.provider.isCloud ? Keychain.read(account: c.provider.rawValue, service: service) : nil)
    }

    /// What the model is told. The answer is dropped into DrawThings.characterPrompt ("…miniature
    /// of a %@, …"), so it has to read as a noun phrase after "of a". `kind` is what the mini is;
    /// only characters exist today, and anything else reads as one until it has its own words.
    public static func systemPrompt(kind: String = "character") -> String {
        """
        You help people make 3D-printable tabletop miniatures. They give you a short idea for a \
        character; you reply with a detailed visual description of that ONE figure, for a picture \
        generator. Describe: who they are, build and proportions, a compact full-body pose with \
        arms, weapons and anything they hold kept close to the body, what they hold and how, \
        clothing, armour and materials as bold chunky shapes, hair and face as clear simple forms. \
        Keep everything the person asked for. Only this one figure: no companions, no background, \
        no scenery, no base, no lighting or camera, no art style, no glow, smoke or flowing \
        effects, no sizes or measurements, and no text, letters or logos. \
        Write a single paragraph of 50 to 80 words that fills the blank in "a miniature of a ___": \
        begin with the figure itself, for example "stout dwarf blacksmith with…", with no article \
        and without repeating "miniature of a". \
        Reply with the description only: no preamble, no quotes, no lists.
        """
    }

    /// Improves a description. Throws a HelperError in plain words; callers keep the original.
    public func improve(_ text: String, kind: String = "character", timeout: TimeInterval = 120) throws -> String {
        let out = Self.clean(try send(system: Self.systemPrompt(kind: kind), user: text, maxTokens: 400, timeout: timeout))
        guard !out.isEmpty else { throw HelperError.empty }
        return out
    }

    /// Settings' Test button: one tiny call that proves the address, key and model.
    public func test(timeout: TimeInterval = 120) throws {
        _ = try send(system: "Reply with the single word OK.", user: "Are you there?", maxTokens: 5, timeout: timeout)
    }

    // MARK: Requests

    /// One request per provider, built in one place so tests can check it without a network.
    func request(system: String, user: String, maxTokens: Int) throws -> URLRequest {
        guard config.provider != .off else { throw HelperError.off }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw HelperError.noModel(config.provider) }
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if config.provider.isCloud && key.isEmpty { throw HelperError.noKey }
        let path = switch config.provider { case .anthropic: "/v1/messages"; case .openai: "/chat/completions"; default: "/api/chat" }
        let base = config.baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + path), url.host != nil else {
            throw HelperError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch config.provider {
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "max_tokens": maxTokens, "system": system,
                    "messages": [["role": "user", "content": user]]]
        case .openai:
            // Only model and messages: some models refuse max_tokens or temperature, and the
            // fewer parameters, the more OpenAI-compatible services accept the request.
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        default:
            body = ["model": model, "stream": false, "options": ["num_predict": maxTokens],
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The text of a reply, or the error it carries.
    static func parse(_ provider: HelperProvider, model: String, status: Int, data: Data) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? json["error"] as? String
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            switch status {
            case 401, 403: throw HelperError.badKey
            case 404: throw HelperError.modelMissing(model, provider)
            case 429, 500...599: throw HelperError.busy
            default: throw HelperError.refused(message)
            }
        }
        let text: String?
        switch provider {
        case .anthropic:
            if json["stop_reason"] as? String == "refusal" { throw HelperError.refused("the model declined this description") }
            text = (json["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        case .openai:
            text = (((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])?["content"] as? String
        default:
            text = (json["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, !text.isEmpty else { throw HelperError.empty }
        return text
    }

    /// Model replies come dressed up now and then: quotes, "a " up front, thinking tags, newlines.
    static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        s = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’` ").union(.whitespaces))
        // Some models repeat the words the answer is dropped after (seen from gemma3).
        s = s.replacingOccurrences(of: "^(a |an )?(full-body )?(fantasy )?(tabletop )?miniature of (a |an )?", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        for article in ["a ", "an ", "the "] where s.lowercased().hasPrefix(article) { s.removeFirst(article.count); break }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func send(system: String, user: String, maxTokens: Int, timeout: TimeInterval) throws -> String {
        var req = try request(system: system, user: user, maxTokens: maxTokens)
        req.timeoutInterval = timeout  // Ollama loads the model on the first call: tens of seconds
        let (provider, model, key) = (config.provider, config.model, key)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(HelperError.empty)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            if let err = err as? URLError { result = .failure(HelperError.from(err, provider)); return }
            guard let data, let http = resp as? HTTPURLResponse else { result = .failure(HelperError.unreachable); return }
            result = Result { try Self.parse(provider, model: model, status: http.statusCode, data: data) }
        }.resume()
        done.wait()
        // A service that echoes the key in its error text must not put it on screen.
        if case .failure(let e) = result, case .refused(let why)? = e as? HelperError, let key, !key.isEmpty {
            throw HelperError.refused(why.replacingOccurrences(of: key, with: "…"))
        }
        return try result.get()
    }

    // MARK: Ollama

    /// The models installed in Ollama, from /api/tags.
    public static func ollamaModels(base: String = HelperProvider.ollama.defaultURL, timeout: TimeInterval = 3) throws -> [String] {
        guard let url = URL(string: base + "/api/tags") else { throw HelperError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<[String], Error> = .failure(HelperError.notRunning)
        URLSession.shared.dataTask(with: req) { data, _, err in
            defer { done.signal() }
            if let err = err as? URLError { result = .failure(HelperError.from(err, .ollama)); return }
            result = .success(parseTags(data ?? Data()))
        }.resume()
        done.wait()
        return try result.get()
    }

    static func parseTags(_ data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
    }
}

public enum HelperError: Error, CustomStringConvertible, Equatable {
    case off, noKey, noModel(HelperProvider), badURL, noInternet, unreachable, timedOut, notRunning, badKey,
         modelMissing(String, HelperProvider), busy, empty, refused(String), keychain(OSStatus)

    static func from(_ e: URLError, _ provider: HelperProvider) -> HelperError {
        switch e.code {
        case .cannotConnectToHost where provider == .ollama: .notRunning
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed: .noInternet
        case .timedOut: .timedOut
        default: .unreachable
        }
    }

    public var description: String {
        switch self {
        case .off: "No AI helper is set up. Choose one in Settings → AI helper for descriptions."
        case .noKey: "No API key saved. Paste yours in Settings → AI helper for descriptions."
        case .noModel(.ollama): "Pick one of your Ollama models in Settings."
        case .noModel: "Type the model's name in Settings."
        case .badURL: "That service address doesn't look right. It should start with https://."
        case .noInternet: "No internet connection. Connect, then try again."
        case .unreachable: "Couldn't reach the service. Check its address in Settings."
        case .timedOut: "The helper took too long to answer. Try again."
        case .notRunning: "Ollama isn't running. Open the Ollama app, then try again."
        case .badKey: "The API key was turned down. Copy it again from your account and save it in Settings."
        case .modelMissing(let m, .ollama): "The model \(m) isn't installed in Ollama. In Terminal: ollama pull \(m)"
        case .modelMissing(let m, _): "The service doesn't know a model called \(m). Check its name in Settings."
        case .busy: "The service is busy right now. Try again in a minute."
        case .empty: "The helper answered with nothing. Try again."
        case .refused(let why): "The helper said no: \(why)"
        case .keychain(let status): "Couldn't save the key in your Keychain (error \(status))."
        }
    }
}
