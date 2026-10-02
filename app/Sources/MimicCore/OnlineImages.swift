import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where step 1's pictures are made (#247): Draw Things on this Mac, the default, or Black Forest
/// Labs' online service with the person's own key. Stored like the helper's provider, so `mimic make`
/// through the PATH symlink reads the app's choice.
public enum ImageService: String, CaseIterable, Sendable {
    case drawThings = "drawthings", bfl
    public static let key = "imageService"
    public static func load(_ d: UserDefaults) -> ImageService { ImageService(rawValue: d.string(forKey: key) ?? "") ?? .drawThings }
}

/// Makes step 1's pictures: draws one from a description, or redraws one as a grey sculpt.
/// Draw Things and the online service both do; the job runner asks whichever was chosen.
public protocol PictureMaker: AnyObject, Sendable {
    func draw(description: String, seed: Int, kind: MiniKind) throws -> Data
    func sculpt(picture: URL, seed: Int, kind: MiniKind, change: String?) throws -> Data
    /// Stop: ends a request in flight, or the next one asked for.
    func cancel()
    /// Forgets an earlier Stop, when a job starts.
    func reset()
}

extension DrawThings: PictureMaker {}

/// Black Forest Labs' API, which runs the same FLUX.2 Klein as Draw Things, so the prompts carry
/// over unchanged. Asynchronous: a request is submitted, then its `polling_url` is asked until the
/// picture is ready, and the picture is fetched from the address it gives.
public final class OnlineImages: PictureMaker, @unchecked Sendable {
    /// The Keychain account the key is saved under (service "com.mimic.app", as the helper's keys).
    public static let keyAccount = "bfl"
    /// Klein 9B: the model Mimic's prompts were written for, and BFL's least expensive.
    public static let model = "flux-2-klein-9b"
    public static let defaultBase = URL(string: "https://api.bfl.ai")!

    let base: URL
    private let key: @Sendable () -> String?
    /// How long a picture may take, and how often to ask whether it's ready.
    var timeout: TimeInterval = 300
    var poll: TimeInterval = 0.5

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var canceled = false

    /// `key` is asked only when a request goes out: reading the Keychain can wait on a prompt.
    public init(base: URL = OnlineImages.defaultBase, key: @escaping @Sendable () -> String?) {
        self.base = base; self.key = key
    }

    /// The service Settings chose, with the key saved for it; nil when pictures are made by Draw Things.
    public static func configured(defaults: UserDefaults, service: String = Keychain.service) -> OnlineImages? {
        guard ImageService.load(defaults) == .bfl else { return nil }
        return OnlineImages { Keychain.read(account: keyAccount, service: service) }
    }

    public func draw(description: String, seed: Int, kind: MiniKind) throws -> Data {
        try make(["prompt": DrawThings.drawPrompt(description, kind: kind), "seed": seed, "width": 1024, "height": 1024])
    }

    public func sculpt(picture: URL, seed: Int, kind: MiniKind, change: String?) throws -> Data {
        // The size Draw Things gets: multiples of 64, which FLUX.2's multiples of 16 accept.
        let (png, w, h) = try DrawThings.fitForEdit(picture)
        return try make(["prompt": DrawThings.redrawPrompt(kind: kind, change: change), "seed": seed, "width": w, "height": h,
                         "input_image": png.base64EncodedString()])
    }

    public func cancel() { lock.withLock { canceled = true; task?.cancel() } }
    public func reset() { lock.withLock { canceled = false } }

    /// Settings' Test and the setup check: asks for the account's credits, which costs nothing
    /// and proves the key.
    public func check(timeout: TimeInterval = 15) throws {
        var req = URLRequest(url: base.appendingPathComponent("v1/credits"))
        req.setValue(try validKey(), forHTTPHeaderField: "x-key")
        req.timeoutInterval = timeout
        _ = try json(req)
    }

    // MARK: Requests

    private func validKey() throws -> String {
        let k = key()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !k.isEmpty else { throw OnlineImagesError.noKey }
        return k
    }

    private func make(_ body: [String: Any]) throws -> Data {
        if lock.withLock({ canceled }) { throw OnlineImagesError.cancelled }
        let key = try validKey()
        var b = body
        // PNG, as Draw Things gives: the default is JPEG. Moderation stays at BFL's default.
        b["output_format"] = "png"
        var submit = URLRequest(url: base.appendingPathComponent("v1/\(Self.model)"))
        submit.httpMethod = "POST"
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.setValue(key, forHTTPHeaderField: "x-key")
        submit.httpBody = try JSONSerialization.data(withJSONObject: b)
        submit.timeoutInterval = 60
        let started = try json(submit)
        guard let polling = (started["polling_url"] as? String).flatMap(URL.init(string:)), sendsKey(to: polling) else {
            throw OnlineImagesError.failed("it gave no address to collect the picture from")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if lock.withLock({ canceled }) { throw OnlineImagesError.cancelled }
            if Date() > deadline { throw OnlineImagesError.timedOut }
            var ask = URLRequest(url: polling)
            ask.setValue(key, forHTTPHeaderField: "x-key")
            ask.timeoutInterval = 30
            let reply = try json(ask)
            switch reply["status"] as? String {
            case "Ready":
                guard let sample = ((reply["result"] as? [String: Any])?["sample"] as? String).flatMap(URL.init(string:)) else {
                    throw OnlineImagesError.failed("no picture in the reply")
                }
                // The delivery address is signed: it needs no key, so none is sent there.
                return try Self.png(fetch(URLRequest(url: sample)).data)
            case "Request Moderated", "Content Moderated":
                let reasons = ((reply["details"] as? [String: Any])?["Moderation Reasons"] as? [String]) ?? []
                throw OnlineImagesError.refused(reasons)
            case "Error", "Task not found", "Failed":
                throw OnlineImagesError.failed(reply["status"] as? String ?? "")
            default:
                // Pending, Reasoning, Generating: asked again shortly, Stop or not.
                let until = Date().addingTimeInterval(poll)
                while Date() < until, !lock.withLock({ canceled }) { usleep(20_000) }
            }
        }
    }

    /// The key goes to BFL's own hosts over https (a polling address may be a regional one), or to
    /// this Mac in tests: never to whatever address a reply names.
    func sendsKey(to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == base.host?.lowercased() && url.scheme == base.scheme { return true }
        return url.scheme == "https" && (host == "bfl.ai" || host.hasSuffix(".bfl.ai"))
    }

    /// A reply's JSON, or the error its status means.
    private func json(_ req: URLRequest) throws -> [String: Any] {
        let (status, data) = try fetch(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200: return json
        case 401, 403: throw OnlineImagesError.badKey
        case 402: throw OnlineImagesError.noCredits
        case 429, 500...599: throw OnlineImagesError.busy
        default:
            var why = (json["detail"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            // A service that echoes the key in its error text must not put it on screen.
            if let k = key(), !k.isEmpty { why = why.replacingOccurrences(of: k, with: "…") }
            throw OnlineImagesError.failed(why)
        }
    }

    private func fetch(_ req: URLRequest) throws -> (status: Int, data: Data) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Int, Data), Error> = .failure(OnlineImagesError.unreachable)
        let t = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            if let err = err as? URLError { result = .failure(OnlineImagesError.from(err)); return }
            guard let data, let http = resp as? HTTPURLResponse else { return }
            result = .success((http.statusCode, data))
        }
        let stopNow = lock.withLock { () -> Bool in
            if !canceled { task = t; t.resume() }
            return canceled
        }
        if stopNow { throw OnlineImagesError.cancelled }
        done.wait()
        lock.withLock { task = nil }
        return try result.get()
    }

    /// PNG bytes, as step 1 writes `source.png`: asked for, but anything else is converted.
    static func png(_ data: Data) throws -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw OnlineImagesError.failed("the picture it sent can't be read")
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw OnlineImagesError.failed("") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw OnlineImagesError.failed("the picture it sent can't be read") }
        return out as Data
    }
}

/// In plain words, since a job keeps `String(describing:)` as why it failed. None names Draw
/// Things: a failure that does is taken for a Draw Things setup problem (JobProgress.drawThingsCaused).
public enum OnlineImagesError: Error, CustomStringConvertible, Equatable {
    case noKey, badKey, noCredits, busy, refused([String]), timedOut, noInternet, unreachable, failed(String), cancelled

    static func from(_ e: URLError) -> OnlineImagesError {
        switch e.code {
        case .cancelled: .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed: .noInternet
        case .timedOut: .timedOut
        default: .unreachable
        }
    }

    public var description: String {
        switch self {
        case .noKey: "No Black Forest Labs key is saved. Paste yours in Settings, under Pictures."
        case .badKey: "Black Forest Labs turned the key down. Copy it again from your account and save it in Settings, under Pictures."
        case .noCredits: "Your Black Forest Labs account is out of credits. Add some on their website, then try again."
        case .busy: "Black Forest Labs is busy, or you've reached your account's limit. Try again in a minute."
        case .refused(let why) where why.isEmpty: "Black Forest Labs wouldn't make this picture. Try different words or another picture."
        case .refused(let why): "Black Forest Labs wouldn't make this picture (\(why.joined(separator: ", ").lowercased())). Try different words or another picture."
        case .timedOut: "Black Forest Labs took too long to make the picture. Try again."
        case .noInternet: "No internet connection. Connect, then try again."
        case .unreachable: "Couldn't reach Black Forest Labs. Try again in a minute."
        case .failed(let why) where why.isEmpty: "Black Forest Labs couldn't make the picture. Try again."
        case .failed(let why): "Black Forest Labs couldn't make the picture: \(why)"
        case .cancelled: "Stopped."
        }
    }
}
