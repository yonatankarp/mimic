import Foundation

extension OnlineService {
    /// Black Forest Labs: the key in `x-key`, sent to `*.bfl.ai` (a polling address may be a
    /// regional one), checked for free by asking for the account's credits.
    public static let bfl = OnlineService(
        name: "Black Forest Labs", keyAccount: "bfl", keyPage: URL(string: "https://dashboard.bfl.ai")!,
        base: URL(string: "https://api.bfl.ai")!, keyHeader: "x-key", keyPrefix: "",
        keyHosts: ["bfl.ai", "*.bfl.ai"], checkPath: "v1/credits",
        client: { BlackForestLabs(base: $0, key: $1) })
}

/// Black Forest Labs' API, which runs the same FLUX.2 Klein as Draw Things, so the prompts carry
/// over unchanged. Asynchronous: a request is submitted, then its `polling_url` is asked until the
/// picture is ready, and the picture is fetched from the address it gives.
public final class BlackForestLabs: OnlineClient, OnlineImages, @unchecked Sendable {
    /// Klein 9B: the model Mimic's prompts were written for, and BFL's least expensive.
    public static let model = "flux-2-klein-9b"

    /// How often to ask whether the picture is ready.
    var poll: TimeInterval = 0.5

    /// `key` is asked only when a request goes out: reading the Keychain can wait on a prompt.
    public init(base: URL = OnlineService.bfl.base, key: @escaping @Sendable () -> String?) {
        super.init(service: .bfl, base: base, key: key)
    }

    public func draw(description: String, seed: Int, kind: MiniKind) throws -> Data {
        try make(["prompt": DrawThings.drawPrompt(description, kind: kind), "seed": seed], width: 1024, height: 1024)
    }

    public func sculpt(picture: URL, seed: Int, kind: MiniKind, change: String?) throws -> Data {
        // The size Draw Things gets: multiples of 64, which FLUX.2's multiples of 16 accept.
        let (png, w, h) = try DrawThings.fitForEdit(picture)
        return try make(["prompt": DrawThings.redrawPrompt(kind: kind, change: change), "seed": seed,
                         "input_image": Self.dataURL(png)], width: w, height: h)
    }

    /// The picture inline, as a data URL: FLUX.2's OpenAPI only says "Path to the input image", and
    /// BFL's own FLUX.2 example sends a local file this way (docs.bfl.ml/cookbook/video_start_from_images).
    static func dataURL(_ png: Data) -> String { "data:image/png;base64," + png.base64EncodedString() }

    /// Asks for the account's credits, which costs nothing and proves the key.
    public func check() throws { _ = try json(try checkRequest(timeout: 15)) }

    // MARK: Requests

    private func make(_ body: [String: Any], width: Int, height: Int) throws -> Data {
        if isCanceled { throw fail(.cancelled) }
        let key = try validKey()
        var b = body
        // PNG, as Draw Things gives: the default is JPEG. Moderation stays at BFL's default.
        b["output_format"] = "png"; b["width"] = width; b["height"] = height
        var submit = request("v1/\(Self.model)", key: key)
        submit.httpMethod = "POST"
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.httpBody = try JSONSerialization.data(withJSONObject: b)
        submit.timeoutInterval = 60
        let started = try json(submit)
        guard let polling = (started["polling_url"] as? String).flatMap(URL.init(string:)), sendsKey(to: polling) else {
            throw fail(.failed("it gave no address to collect the picture from"))
        }
        let deadline = Date().addingTimeInterval(timeout)
        func wait() {
            let until = Date().addingTimeInterval(poll)
            while Date() < until, !isCanceled { usleep(20_000) }
        }
        while true {
            if isCanceled { throw fail(.cancelled) }
            if Date() > deadline { throw fail(.timedOut) }
            var ask = URLRequest(url: polling)
            authorize(&ask, key: key)
            ask.timeoutInterval = 30
            let reply: [String: Any]
            do { reply = try json(ask) } catch let e as OnlineImagesError where [.busy, .timedOut, .unreachable, .noInternet].contains(e.problem) {
                // The request is paid for already: a hiccup while asking is asked again, until the deadline.
                wait(); continue
            }
            switch reply["status"] as? String {
            case "Ready":
                guard let sample = ((reply["result"] as? [String: Any])?["sample"] as? String).flatMap(URL.init(string:)) else {
                    throw fail(.failed("no picture in the reply"))
                }
                // The delivery address is signed: it needs no key, so none is sent there.
                return try png(fetch(URLRequest(url: sample)).data, width: width, height: height)
            case "Request Moderated", "Content Moderated":
                let reasons = ((reply["details"] as? [String: Any])?["Moderation Reasons"] as? [String]) ?? []
                throw fail(.refused(reasons))
            case "Error", "Failed", "Task not found":
                // Task not found is final, as BFL's docs say (and get_result answers it with a 404).
                throw fail(.failed(""))
            default:
                // Pending, Reasoning, Generating: asked again shortly, until the deadline or a Stop.
                wait()
            }
        }
    }

    /// A reply's JSON, or the error its status means.
    private func json(_ req: URLRequest) throws -> [String: Any] {
        let (status, data) = try fetch(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let detail = json["detail"] as? String ?? ""
        switch status {
        case 200: return json
        // A task get_result doesn't know: its status says so, and the poll loop ends on it.
        case 404 where json["status"] is String: return json
        // Seen from api.bfl.ai: no key or an unknown one is 403 "Not authenticated"; a key not
        // shaped like one is 422 "Invalid API key format".
        case 401, 403: throw fail(.badKey)
        case 422 where detail.localizedCaseInsensitiveContains("api key"): throw fail(.badKey)
        case 402: throw fail(.noCredits)
        case 429, 500...599: throw fail(.busy)
        // A service that echoes the key in its error text must not put it on screen.
        default: throw fail(.failed(masked(detail.isEmpty ? String(decoding: data, as: UTF8.self) : detail)))
        }
    }
}
