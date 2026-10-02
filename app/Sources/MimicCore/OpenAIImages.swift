import Foundation

extension OnlineService {
    /// OpenAI: the key in `Authorization: Bearer`, sent to api.openai.com only, checked for free
    /// by listing the models it can use. Its own Keychain account: the description helper's
    /// OpenAI key is "openai", and removing one mustn't remove the other.
    public static let openai = OnlineService(
        name: "OpenAI", keyAccount: "openai-images", keyPage: URL(string: "https://platform.openai.com/api-keys")!,
        base: URL(string: "https://api.openai.com")!, keyHeader: "Authorization", keyPrefix: "Bearer ",
        keyHosts: ["api.openai.com"], checkPath: "v1/models",
        client: { OpenAIImages(base: $0, key: $1) })
}

/// OpenAI's Image API: one request a picture, which comes back in the reply as base64. Text to
/// picture is `images/generations` (JSON); picture to picture is `images/edits`, with the picture
/// sent as a file (multipart). Synchronous, so Stop cancels the request itself; there's no seed.
/// The prompts are FLUX's, unchanged (NOTES.md says why).
public final class OpenAIImages: OnlineClient, OnlineImages, @unchecked Sendable {
    /// OpenAI recommends Sunburst for generating and editing images (its DALL·E 3 page); Flare is
    /// the faster one for everyday pictures. A grey sculpt has to keep the character, so Sunburst.
    public static let model = "gpt-image-2.5-sunburst"

    public init(base: URL = OnlineService.openai.base, key: @escaping @Sendable () -> String?) {
        super.init(service: .openai, base: base, key: key)
    }

    public func draw(description: String, seed: Int, kind: MiniKind) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: Self.fields(prompt: DrawThings.drawPrompt(description, kind: kind), width: 1024, height: 1024))
        return try make("v1/images/generations", contentType: "application/json", body: body, width: 1024, height: 1024)
    }

    public func sculpt(picture: URL, seed: Int, kind: MiniKind, change: String?) throws -> Data {
        let (png, w, h) = try DrawThings.fitForEdit(picture)
        let boundary = "mimic-" + UUID().uuidString
        var body = Data()
        for (name, value) in Self.fields(prompt: DrawThings.redrawPrompt(kind: kind, change: change), width: w, height: h).sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"picture.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try make("v1/images/edits", contentType: "multipart/form-data; boundary=\(boundary)", body: body, width: w, height: h)
    }

    /// What both requests ask for: a PNG on an opaque background (a see-through one would leave
    /// the 3D step nothing to cut out), at `size`.
    static func fields(prompt: String, width: Int, height: Int) -> [String: String] {
        ["model": model, "prompt": prompt, "size": size(width: width, height: height), "output_format": "png", "background": "opaque"]
    }

    /// The size asked for: the one wanted when the model takes it (sides in multiples of 16, at
    /// most 3:1, 655,360 to 8,294,400 pixels), else the nearest of its usual three. Whatever
    /// comes back is scaled to the size wanted, stretched: so the shape of the usual size has
    /// to be the nearest, or the figure comes out squashed.
    static func size(width: Int, height: Int) -> String {
        let ratio = Double(max(width, height)) / Double(min(width, height))
        let pixels = width * height
        if width % 16 == 0, height % 16 == 0, ratio <= 3, (655_360...8_294_400).contains(pixels) { return "\(width)x\(height)" }
        if ratio < 1.25 { return "1024x1024" }
        return width > height ? "1536x1024" : "1024x1536"
    }

    /// Lists the models the key can use, which costs nothing and proves it.
    public func check() throws { _ = try json(try checkRequest(timeout: 15)) }

    // MARK: Requests

    private func make(_ path: String, contentType: String, body: Data, width: Int, height: Int) throws -> Data {
        if isCanceled { throw fail(.cancelled) }
        var req = request(path, key: try validKey())
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        // A picture can take two minutes or more, with nothing sent meanwhile.
        req.timeoutInterval = timeout
        let reply = try json(req)
        guard let b64 = ((reply["data"] as? [[String: Any]])?.first?["b64_json"] as? String), let picture = Data(base64Encoded: b64) else {
            throw fail(.failed("no picture in the reply"))
        }
        return try png(picture, width: width, height: height)
    }

    /// A reply's JSON, or the error it carries: `{"error": {"message", "type", "code"}}`.
    private func json(_ req: URLRequest) throws -> [String: Any] {
        let (status, data) = try fetch(req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = json["error"] as? [String: Any] ?? [:]
        let code = error["code"] as? String
        switch status {
        case 200: return json
        // Seen from api.openai.com: a made-up key, or none, is 401 "invalid_api_key". Its message
        // shows part of the key, so it's never passed on.
        case 401: throw fail(.badKey)
        case 429 where code == "insufficient_quota": throw fail(.noCredits)
        case 429, 500...599: throw fail(.busy)
        case 400 where code == "moderation_blocked":
            throw fail(.refused((error["moderation_details"] as? [String: Any])?["categories"] as? [String] ?? []))
        // Anything else, such as 403 for an organisation that isn't verified for the model yet,
        // in OpenAI's own words.
        default: throw fail(.failed(masked(error["message"] as? String ?? String(decoding: data, as: UTF8.self))))
        }
    }
}
