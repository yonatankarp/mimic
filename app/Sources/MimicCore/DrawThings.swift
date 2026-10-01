import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draw Things: draws a character from a description, or redraws a picture as a grey
/// sculpt. Every request names its model and sampler: left out, the API renders with whatever
/// the app happens to have selected, and with SDXL selected an edit silently became plain
/// text-to-image at strength 1, ignoring the picture.
///
/// With `draw-things-cli`, which setup downloads beside the 3D engine, it runs that instead: it
/// needs neither the app open nor its API server on. The API is the fallback when it isn't there.
public final class DrawThings: @unchecked Sendable {
    public let base: URL
    public let modelsDir: URL
    private let pinnedModel: String?
    /// Mimic's `draw-things-cli`, when it's there: pictures are made with it instead of the API.
    public let cli: String?
    /// Opens Draw Things when a picture needs it (`openIfNeeded`).
    public let app: DrawThingsApp
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var process: Process?
    private var canceled = false

    /// FLUX.2 Klein is step-distilled: these are the settings it was made for.
    static var settings: [String: Any] { [
        "steps": 4, "sampler": "DDIM Trailing", "guidance_scale": 1.0, "shift": 3.0,
        "resolution_dependent_shift": false, "seed_mode": "Scale Alike",
        "loras": [Any](), "controls": [Any](), "refiner_model": NSNull(),
    ] }

    public static let characterPrompt = "full-body fantasy tabletop miniature of a %@, heroic proportions, compact pose, limbs and weapons held close to the body, bold chunky details, entire figure visible from head to feet, standing on nothing, no base, no pedestal, front view, centered, plain light grey studio background, unpainted grey 3D render"
    public static let sculptPrompt = "Turn this character into an unpainted grey plastic tabletop miniature sculpt. Keep the same character, pose, face, clothing, weapons and accessories. Clean sculpted forms, bold readable shapes, slightly larger head and hands, feet or hem resting on the ground, no base. Plain light grey studio background, soft even lighting, 3D render."

    /// For anything that isn't a character: one object, whole and unpainted, on nothing. Eye
    /// level, like the character's front view: drawn "slightly from above", a teapot came out
    /// of the 3D engine tipped about 20° and stood on its belly (seen once; the eye-level
    /// wording is not yet seen through the engine).
    public static let objectPrompt = "%@. One single object on its own, the whole object fully visible and centered with space around it, nothing cut off, front view at eye level, solid simple forms, unpainted grey 3D render, smooth matte grey clay material, plain light grey studio background, soft even lighting, no added base or pedestal, no text"
    public static let objectSculptPrompt = "Turn this object into an unpainted grey plastic 3D sculpt. Keep the same object, shape, proportions and details. Only this one object, whole and fully visible, centered. Clean sculpted forms, bold readable shapes, no base unless it is part of the object. Plain light grey studio background, soft even lighting, 3D render."

    public static func drawPrompt(_ description: String, kind: MiniKind) -> String {
        String(format: kind == .object ? objectPrompt : characterPrompt, description)
    }
    /// The grey sculpt redraw, with a fix the person typed (#156) said before what it keeps, as
    /// the one thing to change: so "keep the same weapons" doesn't undo "a shorter sword".
    public static func redrawPrompt(kind: MiniKind, change: String? = nil) -> String {
        let prompt = kind == .object ? objectSculptPrompt : sculptPrompt
        let fix = (change ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fix.isEmpty else { return prompt }
        let said = ".!?".contains(fix.last!) ? fix : fix + "."
        return prompt.replacingOccurrences(of: " Keep the same", with: " Make this one change: \(said) Apart from that change, keep the same")
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser, app: DrawThingsApp = .mac,
                cli: String? = DrawThings.findCLI()) {
        base = URL(string: environment["DRAWTHINGS_URL"] ?? "http://127.0.0.1:7860")!
        modelsDir = home.appendingPathComponent("Library/Containers/com.liuliu.draw-things/Data/Documents/Models")
        pinnedModel = environment["DRAWTHINGS_MODEL"]
        self.app = app
        self.cli = cli
    }

    /// Mimic's own copy of `draw-things-cli`, which setup downloads, when it's there.
    public static func findCLI(_ install: Install = .locate()) -> String? {
        let path = install.drawThingsCLI.path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Before a picture step: when the API isn't answering and Draw Things isn't running, opens
    /// it in the background and waits for the API. Returns the instance Mimic opened (Mimic's to
    /// quit afterwards), or nil when it didn't open one: already answering, switched off in
    /// Settings, not installed, or running already (its API server off, which the request then
    /// says). The wait ends when the API answers or the app exits, else after `cap`: an app that
    /// opens and never answers almost always has its API server off.
    public func openIfNeeded(cap: TimeInterval = 90, poll: TimeInterval = 0.5,
                             canceled: () -> Bool = { false }, opening: () -> Void = {}) throws -> DrawThingsApp.Instance? {
        if cli != nil || reachable() { return nil }
        guard app.enabled(), !app.running() else { return nil }
        opening()
        guard let opened = app.open() else { return nil }
        let deadline = Date().addingTimeInterval(cap)
        while !reachable(timeout: 1) {
            if canceled() { opened.quit(); throw DrawThingsError.cancelled }
            if !opened.alive() { throw DrawThingsError.closedWhileOpening }
            if Date() > deadline { opened.quit(); throw DrawThingsError.apiOff }
            Thread.sleep(forTimeInterval: poll)
        }
        return opened
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

    /// The `draw-things-cli generate` arguments for the same request. The pinned release only
    /// generates locally and has no `--local` (it refuses it); later builds add cloud compute and
    /// may use it unless given `--local`, so a new pin has to check its `generate --help`.
    static func cliArguments(model: String, prompt: String, seed: Int, width: Int, height: Int,
                             image: String? = nil, output: String) -> [String] {
        var a = ["generate", "--no-download-missing", "--disable-preview", "--model", model, "--prompt", prompt,
                 "--seed", String(seed), "--width", String(width), "--height", String(height), "--steps", "4", "--cfg", "1"]
        if let image { a += ["--image", image, "--strength", "1"] }
        return a + ["--output", output]
    }

    /// The file the CLI says it wrote ("Wrote: <path>"), from output full of progress lines.
    static func wrotePath(_ output: String) -> String? {
        lines(output).last { $0.contains("Wrote: ") }.map { String($0[$0.range(of: "Wrote: ")!.upperBound...]) }
    }

    /// The last lines of what the CLI printed: what went wrong.
    static func tail(_ output: String) -> String { lines(output).suffix(3).joined(separator: " ") }

    /// The CLI's output as lines, without its terminal codes or blank lines.
    static func lines(_ output: String) -> [String] {
        output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func runCLI(_ cli: String, model: String, prompt: String, seed: Int, width: Int, height: Int, image: Data? = nil) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mimic-dt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.png"), output = dir.appendingPathComponent("out.png")
        if let image { try image.write(to: input) }
        // At the same lower priority as a job's other programs (#136). nice runs the CLI in its own
        // place, so Stop still ends it.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", String(JobRunner.nice), cli]
            + Self.cliArguments(model: model, prompt: prompt, seed: seed, width: width, height: height,
                                image: image == nil ? nil : input.path, output: output.path)
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        let stopNow = try lock.withLock { () -> Bool in
            if !canceled { try p.run(); process = p }
            return canceled
        }
        if stopNow { throw DrawThingsError.cancelled }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let wasCanceled = lock.withLock { () -> Bool in process = nil; return canceled }
        if wasCanceled { throw DrawThingsError.cancelled }
        guard p.terminationStatus == 0 else { throw DrawThingsError.refused(Self.tail(text)) }
        guard let png = try? Data(contentsOf: URL(fileURLWithPath: Self.wrotePath(text) ?? output.path)) else {
            throw DrawThingsError.refused("no picture in the reply")
        }
        return png
    }

    /// Draws a character from a description. Returns PNG data.
    public func draw(description: String, seed: Int, kind: MiniKind = .character) throws -> Data {
        guard let model = model() else { throw DrawThingsError.noModel }
        if let cli { return try runCLI(cli, model: model, prompt: Self.drawPrompt(description, kind: kind), seed: seed, width: 1024, height: 1024) }
        return try send("sdapi/v1/txt2img", body(model: model, prompt: Self.drawPrompt(description, kind: kind),
                                                 seed: seed, width: 1024, height: 1024))
    }

    /// Redraws a picture as a grey sculpt of the same character, making `change` when given
    /// (#156). Returns PNG data.
    public func sculpt(picture: URL, seed: Int, kind: MiniKind = .character, change: String? = nil) throws -> Data {
        guard let model = model() else { throw DrawThingsError.noModel }
        let (png, w, h) = try Self.fitForEdit(picture)
        let prompt = Self.redrawPrompt(kind: kind, change: change)
        if let cli { return try runCLI(cli, model: model, prompt: prompt, seed: seed, width: w, height: h, image: png) }
        return try send("sdapi/v1/img2img", body(model: model, prompt: prompt, seed: seed, width: w, height: h, image: png))
    }

    /// Stops a request in flight (Stop during the picture step), or the next one asked for: a
    /// Stop while the model is looked up or the picture resized still counts (#170).
    public func cancel() { lock.withLock { canceled = true; task?.cancel(); process?.terminate() } }

    /// Forgets an earlier Stop: when a job starts, before it can be stopped.
    public func reset() { lock.withLock { canceled = false } }

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
        let stopNow = lock.withLock { () -> Bool in
            if !canceled { task = t; t.resume() }
            return canceled
        }
        if stopNow { throw DrawThingsError.cancelled }
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
        guard let image = try? Engine.load(url) else { throw DrawThingsError.badPicture }
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

/// Opening and quitting the Draw Things app: an input, so tests never touch the real one.
public struct DrawThingsApp: Sendable {
    /// One running Draw Things that Mimic opened. Only this is ever quit: one the person opened
    /// themselves is never Mimic's.
    public struct Instance: Sendable {
        public var alive: @Sendable () -> Bool
        /// Asks it to quit, as ⌘Q does; never forced.
        public var quit: @Sendable () -> Void
        public init(alive: @escaping @Sendable () -> Bool, quit: @escaping @Sendable () -> Void) { self.alive = alive; self.quit = quit }
    }
    /// Settings → Open Draw Things when needed.
    public var enabled: @Sendable () -> Bool
    /// Whether any Draw Things is running, whoever opened it.
    public var running: @Sendable () -> Bool
    /// Opens it without taking focus; nil when it isn't installed or won't open.
    public var open: @Sendable () -> Instance?

    public init(enabled: @escaping @Sendable () -> Bool, running: @escaping @Sendable () -> Bool,
                open: @escaping @Sendable () -> Instance?) {
        self.enabled = enabled; self.running = running; self.open = open
    }

    public static let bundleID = "com.liuliu.draw-things"
    /// The Settings switch, on unless turned off.
    public static let enabledKey = "openDrawThings"
    public static func enabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }

    /// The real one, through NSWorkspace: works from the app and from `mimic` in Terminal.
    public static let mac = workspace(bundleID)

    /// Any app by bundle id: Draw Things, or another app to try opening and quitting live.
    static func workspace(_ bundleID: String) -> DrawThingsApp { DrawThingsApp(
        enabled: { enabled() },
        running: { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty },
        open: {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false; config.hides = true; config.addsToRecentItems = false
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var opened: NSRunningApplication?
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in opened = app; done.signal() }
            // ponytail: bounded in case the reply never comes; a launch takes about a second.
            guard done.wait(timeout: .now() + 60) == .success, let app = opened else { return nil }
            let pid = app.processIdentifier
            // By pid, not isTerminated: that is updated on the main run loop, which `mimic` in
            // Terminal doesn't run. Draw Things isn't Mimic's child, so no zombie keeps it "alive".
            return Instance(alive: { kill(pid, 0) == 0 }, quit: { _ = app.terminate() })
        })
    }
}

public enum DrawThingsError: Error, CustomStringConvertible, Equatable {
    case notRunning, noModel, cancelled, badPicture, refused(String), apiOff, closedWhileOpening
    public var description: String {
        switch self {
        case .notRunning: "Draw Things isn't answering. Open Draw Things, then Settings → Advanced → API Server: turn it on, HTTP, port 7860."
        case .noModel: "FLUX.2 Klein isn't downloaded in Draw Things. Search for it in Draw Things' model list and download it."
        case .cancelled: "Stopped."
        case .badPicture: "That picture can't be read."
        case .refused(let why): "Draw Things refused the request: \(why)"
        case .apiOff: "Mimic opened Draw Things, but it didn't answer. In Draw Things: Settings → Advanced → API Server: turn it on, choose HTTP, port 7860. Then try again."
        case .closedWhileOpening: "Draw Things closed before it was ready. Try again."
        }
    }
}
