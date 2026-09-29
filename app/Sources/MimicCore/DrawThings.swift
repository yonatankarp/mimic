import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draw Things' HTTP API: draws a character from a description, or redraws a picture as a grey
/// sculpt. Every request names its model and sampler: left out, the API renders with whatever
/// the app happens to have selected, and with SDXL selected an edit silently became plain
/// text-to-image at strength 1, ignoring the picture.
public final class DrawThings: @unchecked Sendable {
    public let base: URL
    public let modelsDir: URL
    private let pinnedModel: String?
    private let lock = NSLock()
    private var task: URLSessionDataTask?

    /// FLUX.2 Klein is step-distilled: these are the settings it was made for.
    static var settings: [String: Any] { [
        "steps": 4, "sampler": "DDIM Trailing", "guidance_scale": 1.0, "shift": 3.0,
        "resolution_dependent_shift": false, "seed_mode": "Scale Alike",
        "loras": [Any](), "controls": [Any](), "refiner_model": NSNull(),
    ] }

    public static let characterPrompt = "full-body fantasy tabletop miniature of a %@, heroic proportions, compact pose, limbs and weapons held close to the body, bold chunky details, entire figure visible from head to feet, standing on nothing, no base, no pedestal, front view, centered, plain light grey studio background, unpainted grey 3D render"
    public static let sculptPrompt = "Turn this character into an unpainted grey plastic tabletop miniature sculpt. Keep the same character, pose, face, clothing, weapons and accessories. Clean sculpted forms, bold readable shapes, slightly larger head and hands, feet or hem resting on the ground, no base. Plain light grey studio background, soft even lighting, 3D render."

    /// For anything that isn't a character: one object, whole and unpainted, on nothing.
    public static let objectPrompt = "%@. One single object on its own, the whole object fully visible and centered with space around it, nothing cut off, three-quarter view from slightly above, solid simple forms, unpainted grey 3D render, smooth matte grey clay material, plain light grey studio background, soft even lighting, no added base or pedestal, no text"
    public static let objectSculptPrompt = "Turn this object into an unpainted grey plastic 3D sculpt. Keep the same object, shape, proportions and details. Only this one object, whole and fully visible, centered. Clean sculpted forms, bold readable shapes, no base unless it is part of the object. Plain light grey studio background, soft even lighting, 3D render."

    public static func drawPrompt(_ description: String, kind: MiniKind) -> String {
        String(format: kind == .object ? objectPrompt : characterPrompt, description)
    }
    public static func redrawPrompt(kind: MiniKind) -> String { kind == .object ? objectSculptPrompt : sculptPrompt }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        base = URL(string: environment["DRAWTHINGS_URL"] ?? "http://127.0.0.1:7860")!
        modelsDir = home.appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")
        pinnedModel = environment["DRAWTHINGS_MODEL"]
    }

    /// The Klein checkpoint to ask for: DRAWTHINGS_MODEL, else the one Draw Things has selected if
    /// it's a Klein, else the largest one downloaded ("9b" sorts after "4b").
    ///
    /// Asking the app comes first because the downloads live in Draw Things' private folder:
    /// reading it makes macOS ask the person for access to another app's data, and the read
    /// waits for the answer. So it's the fallback, and it gives up after `timeout`.
    public func model(timeout: TimeInterval = 3) -> String? {
        if let pinnedModel { return pinnedModel }
        if let current = selectedModel(), current.hasPrefix("flux_2_klein") { return current }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var found: String?
        let dir = modelsDir.path
        DispatchQueue.global().async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            found = names.filter { $0.hasPrefix("flux_2_klein") && $0.hasSuffix(".ckpt") }.sorted().last
            done.signal()
        }
        // ponytail: a read still waiting on the prompt is left behind, not cancelled; the next call starts another.
        return done.wait(timeout: .now() + timeout) == .success ? found : nil
    }

    /// The model selected in Draw Things right now, or nil when it isn't reachable.
    func selectedModel(timeout: TimeInterval = 1.5) -> String? {
        var req = URLRequest(url: base.appendingPathComponent("sdapi/v1/options"))
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var model: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            model = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["model"] as? String
            done.signal()
        }.resume()
        done.wait()
        return model
    }

    public func reachable(timeout: TimeInterval = 1.5) -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("sdapi/v1/options"))
        req.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        done.wait()
        return ok
    }

    /// The JSON body of a request, built in one place so it can be checked without a server.
    func body(model: String, prompt: String, seed: Int, width: Int, height: Int, image: Data? = nil) -> [String: Any] {
        var b = Self.settings
        b["model"] = model; b["prompt"] = prompt; b["seed"] = seed; b["width"] = width; b["height"] = height
        if let image { b["init_images"] = [image.base64EncodedString()]; b["strength"] = 1.0 }
        return b
    }

    /// Draws a character from a description. Returns PNG data.
    public func draw(description: String, seed: Int, kind: MiniKind = .character) throws -> Data {
        guard let model = model() else { throw DrawThingsError.noModel }
        return try send("sdapi/v1/txt2img", body(model: model, prompt: Self.drawPrompt(description, kind: kind),
                                                 seed: seed, width: 1024, height: 1024))
    }

    /// Redraws a picture as a grey sculpt of the same character. Returns PNG data.
    public func sculpt(picture: URL, seed: Int, kind: MiniKind = .character) throws -> Data {
        guard let model = model() else { throw DrawThingsError.noModel }
        let (png, w, h) = try Self.fitForEdit(picture)
        return try send("sdapi/v1/img2img", body(model: model, prompt: Self.redrawPrompt(kind: kind), seed: seed, width: w, height: h, image: png))
    }

    /// Stops a request in flight (Stop during the picture step).
    public func cancel() { lock.withLock { task?.cancel() } }

    private func send(_ path: String, _ body: [String: Any]) throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 900
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Data, Error> = .failure(DrawThingsError.notRunning)
        let t = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { done.signal() }
            if let err = err as? URLError, err.code == .cancelled { result = .failure(DrawThingsError.cancelled); return }
            guard err == nil, let data, let http = resp as? HTTPURLResponse else { result = .failure(DrawThingsError.notRunning); return }
            guard http.statusCode == 200 else {
                result = .failure(DrawThingsError.refused(String(decoding: data.prefix(300), as: UTF8.self))); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["images"] as? [String])?.first, let png = Data(base64Encoded: first) else {
                result = .failure(DrawThingsError.refused("no picture in the reply")); return
            }
            result = .success(png)
        }
        lock.withLock { task = t }
        t.resume()
        done.wait()
        lock.withLock { task = nil }
        return try result.get()
    }

    /// Draw Things wants width and height equal to the picture's, in multiples of 64. The long
    /// side goes to 1536.
    static func editSize(width: Int, height: Int) -> (Int, Int) {
        let s = 1536.0 / Double(max(width, height))
        func r(_ v: Int) -> Int { max(64, Int((Double(v) * s / 64).rounded()) * 64) }
        return (r(width), r(height))
    }

    static func fitForEdit(_ url: URL) throws -> (Data, Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw DrawThingsError.badPicture }
        let (w, h) = editSize(width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw DrawThingsError.badPicture
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { throw DrawThingsError.badPicture }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw DrawThingsError.badPicture }
        CGImageDestinationAddImage(dest, scaled, nil)
        guard CGImageDestinationFinalize(dest) else { throw DrawThingsError.badPicture }
        return (out as Data, w, h)
    }
}

public enum DrawThingsError: Error, CustomStringConvertible, Equatable {
    case notRunning, noModel, cancelled, badPicture, refused(String)
    public var description: String {
        switch self {
        case .notRunning: "Draw Things isn't answering. Open Draw Things, then Settings → Advanced → API Server: turn it on, HTTP, port 7860."
        case .noModel: "FLUX.2 Klein isn't downloaded in Draw Things. Search for it in Draw Things' model list and download it."
        case .cancelled: "Stopped."
        case .badPicture: "That picture can't be read."
        case .refused(let why): "Draw Things refused the request: \(why)"
        }
    }
}
